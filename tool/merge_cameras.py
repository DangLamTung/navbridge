#!/usr/bin/env python3
"""Merge the geocoded kiemtraphatnguoi points into the shipped camera DB.

The bundled DB is 30,990 points, 77% of which are VietMap rows named
"Camera giám sát giao thông" with `district: "VietMap"` — position but no
meaning. The new set is the opposite: exact violation behaviour, the CSGT unit,
the camera code, but no coordinates until we geocoded them. Merging adds the
semantics; the dedup stops the same gantry appearing twice 40 m apart.

Dedup radius is 120 m on purpose: a camera site spans the carriageway, and the
geocoder's roof/segment snap can move a point most of that distance.

    python3 tool/merge_cameras.py --dry
    python3 tool/merge_cameras.py
"""
import argparse
import collections
import datetime
import json
import math
import os
import shutil

SRC = 'tool/data/vn_cams_geo.json'
DB = 'assets/offline_map/vietnam_cameras.json'
RADIUS_M = 120.0

# 'violations' from the scrape means "phạt nguội, behaviour not otherwise
# classified" — that is exactly the app's `penalty_camera` type (urgency -100),
# NOT `traffic_camera` (+150, plain surveillance), which would rank a real
# fine camera below the noise VietMap already contributes.
TYPE_BY_FOCUS = {
    'speed': 'speed_camera',
    'red_light': 'red_light_camera',
    'violations': 'penalty_camera',
}

PROVINCE_NAME = {
    'an-giang': 'An Giang', 'bac-ninh': 'Bắc Ninh', 'ca-mau': 'Cà Mau',
    'can-tho': 'Cần Thơ', 'cao-bang': 'Cao Bằng', 'da-nang': 'Đà Nẵng',
    'dak-lak': 'Đắk Lắk', 'dien-bien': 'Điện Biên', 'dong-nai': 'Đồng Nai',
    'dong-thap': 'Đồng Tháp', 'gia-lai': 'Gia Lai', 'ha-noi': 'Hà Nội',
    'ha-tinh': 'Hà Tĩnh', 'hai-phong': 'Hải Phòng', 'hue': 'Huế',
    'hung-yen': 'Hưng Yên', 'khanh-hoa': 'Khánh Hòa', 'lam-dong': 'Lâm Đồng',
    'lang-son': 'Lạng Sơn', 'lao-cai': 'Lào Cai', 'nghe-an': 'Nghệ An',
    'ninh-binh': 'Ninh Bình', 'phu-tho': 'Phú Thọ', 'quang-ngai': 'Quảng Ngãi',
    'quang-ninh': 'Quảng Ninh', 'quang-tri': 'Quảng Trị', 'son-la': 'Sơn La',
    'tay-ninh': 'Tây Ninh', 'thai-nguyen': 'Thái Nguyên',
    'thanh-hoa': 'Thanh Hóa', 'tp-ho-chi-minh': 'TP. Hồ Chí Minh',
    'tuyen-quang': 'Tuyên Quang', 'vinh-long': 'Vĩnh Long',
}


def metres(a1, o1, a2, o2):
    r = 6371000.0
    p1, p2 = math.radians(a1), math.radians(a2)
    dp, dl = math.radians(a2 - a1), math.radians(o2 - o1)
    h = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(min(1.0, h)))


class Grid:
    """Bucket points by ~0.002 deg (~220 m) so a radius query touches 9 cells."""

    def __init__(self, cell=0.002):
        self.cell = cell
        self.b = collections.defaultdict(list)

    def key(self, lat, lng):
        return (int(math.floor(lat / self.cell)), int(math.floor(lng / self.cell)))

    def add(self, lat, lng, item):
        self.b[self.key(lat, lng)].append(item)

    def near(self, lat, lng, radius_m):
        ky, kx = self.key(lat, lng)
        # 0.002 deg of latitude ≈ 222 m, so 3x3 cells always covers 120 m
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for it in self.b.get((ky + dy, kx + dx), ()):
                    if metres(lat, lng, it[1]['lat'], it[1]['lng']) <= radius_m:
                        yield it


def is_nameless_vietmap(c):
    return (c.get('source') == 'vietmap'
            and (c.get('name') or '').strip().lower()
            in ('camera giám sát giao thông', 'camera'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--radius', type=float, default=RADIUS_M)
    a = ap.parse_args()

    db = json.load(open(DB, encoding='utf-8'))
    new = json.load(open(SRC, encoding='utf-8'))
    before = len(db['cameras'])
    print(f'DB now      : {before}')
    print(f'new points  : {len(new)}')

    grid = Grid()
    for i, c in enumerate(db['cameras']):
        grid.add(c['lat'], c['lng'], (i, c))

    # precise first, so the best point wins any collision inside the new set
    new.sort(key=lambda r: (r['precision'] != 'precise', r['name']))
    added = upgraded = dup_existing = dup_new = dropped = 0
    new_grid = Grid()
    upgrade_at = {}
    drop_idx = set()
    for r in new:
        # 1. same place already in the new batch
        if any(True for _ in new_grid.near(r['lat'], r['lng'], a.radius)):
            dup_new += 1
            continue
        hits = list(grid.near(r['lat'], r['lng'], a.radius))
        if hits:
            # 2. an existing point is here. Upgrade it only if it is a VietMap
            #    row that says nothing; otherwise the existing data wins.
            rich = [h for h in hits if not is_nameless_vietmap(h[1])]
            if rich:
                dup_existing += 1
                continue
            idx, old = hits[0]
            row = {
                'name': r['name'], 'lat': r['lat'], 'lng': r['lng'],
                'focus': r['focus'], 'type': TYPE_BY_FOCUS.get(
                    r['focus'], 'penalty_camera'),
                'district': PROVINCE_NAME.get(r['district'], r['district']),
                'source': 'kiemtraphatnguoi',
                'precision': r['precision'],
                'formatted_address': r.get('formatted_address'),
                'code': r.get('code'),
                'unit': r.get('provider'),
                'behaviours': r.get('behaviours', []),
            }
            upgrades = (idx, row)
            upgrade_at[idx] = row
            # The OTHER nameless VietMap rows inside the radius must go too:
            # they are plain 'violations' surveillance points, so leaving them
            # next to our 'penalty_camera' row breaks the DB's guarantee of no
            # same-focus pair within 80 m (data_integrity_test asserts it).
            for other_idx, other in hits:
                if other_idx != idx and is_nameless_vietmap(other):
                    drop_idx.add(other_idx)
                    dropped += 1
            upgraded += 1
            new_grid.add(r['lat'], r['lng'], (None, r))
            continue
        # 3. genuinely new
        db['cameras'].append({
            'name': r['name'], 'lat': r['lat'], 'lng': r['lng'],
            'focus': r['focus'],
            'type': TYPE_BY_FOCUS.get(r['focus'], 'penalty_camera'),
            'district': PROVINCE_NAME.get(r['district'], r['district']),
            'source': 'kiemtraphatnguoi',
            'precision': r['precision'],
            'formatted_address': r.get('formatted_address'),
            'code': r.get('code'),
            'unit': r.get('provider'),
            'behaviours': r.get('behaviours', []),
        })
        new_grid.add(r['lat'], r['lng'], (None, r))
        added += 1

    # apply the upgrades and drops in ONE rebuild — index bookkeeping stays
    # correct even though new rows were appended to the same list
    cams = []
    for i, c in enumerate(db['cameras']):
        if i in drop_idx:
            continue
        cams.append(upgrade_at.get(i, c))
    db['cameras'] = cams

    names = list(db.get('provinces') or [])
    for slug, nm in PROVINCE_NAME.items():
        if nm not in names:
            names.append(nm)
    db['provinces'] = names
    db['version'] = int(db.get('version') or 0) + 1
    db['generated'] = datetime.date.today().isoformat()

    print(f'\nadded      : {added}')
    print(f'upgraded   : {upgraded}  (nameless VietMap rows replaced)')
    print(f'dropped    : {dropped}  (redundant nameless VietMap rows near an upgrade)')
    print(f'dupe (old) : {dup_existing}')
    print(f'dupe (new) : {dup_new}')
    print(f'DB after   : {len(db["cameras"])}  (version {db["version"]})')
    print('by source  :', dict(collections.Counter(
        c.get('source') for c in db['cameras'])))

    if a.dry:
        print('\n(dry run — nothing written)')
        return

    bak = f'{DB}.bak-{datetime.date.today().isoformat()}'
    if not os.path.exists(bak):
        shutil.copy2(DB, bak)
        print(f'backup     : {bak}')
    json.dump(db, open(DB, 'w'), ensure_ascii=False, separators=(',', ':'))
    print(f'wrote      : {DB} ({os.path.getsize(DB) / 1e6:.1f} MB)')


if __name__ == '__main__':
    main()
