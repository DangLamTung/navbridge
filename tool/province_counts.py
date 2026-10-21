#!/usr/bin/env python3
"""Count the shipped camera DB by province.

Why not group by the `district` field: 23,652 VietMap rows literally say
"VietMap" and the Waze rows mostly say nothing, so a groupby answers a
different question than the one asked. Instead every point is assigned to a
province by point-in-polygon against Nominatim boundaries (cached).

Province set = the post-2025 33 units, i.e. the same names the phạt-nguội
listing uses, so the counts line up with the scrape.

    python3 tool/province_counts.py                # table
    python3 tool/province_counts.py --refresh      # re-download polygons
    python3 tool/province_counts.py --by-source    # add a source breakdown
"""
import argparse
import collections
import json
import os
import sys
import time
import urllib.parse
import urllib.request

DB = 'assets/offline_map/vietnam_cameras.json'
POLY = 'tool/data/province_polys.json'
UA = 'NavBridge-camera-audit/1.0 (contact: local dev)'

PROVINCES = [
    'An Giang', 'Bắc Ninh', 'Cà Mau', 'Cần Thơ', 'Cao Bằng', 'Đà Nẵng',
    'Đắk Lắk', 'Điện Biên', 'Đồng Nai', 'Đồng Tháp', 'Gia Lai', 'Hà Nội',
    'Hà Tĩnh', 'Hải Phòng', 'Huế', 'Hưng Yên', 'Khánh Hòa', 'Lâm Đồng',
    'Lạng Sơn', 'Lào Cai', 'Nghệ An', 'Ninh Bình', 'Phú Thọ', 'Quảng Ngãi',
    'Quảng Ninh', 'Quảng Trị', 'Sơn La', 'Tây Ninh', 'Thái Nguyên',
    'Thanh Hóa', 'Hồ Chí Minh', 'Tuyên Quang', 'Vĩnh Long',
]


# Provinces abolished in the 2025 merger whose Nominatim polygon still exists
# separately, so points inside them would otherwise be "unassigned". Only the
# ones that actually showed up as gaps in the count are listed.
ABSORBED = {
    'Hà Nam': 'Ninh Bình', 'Nam Định': 'Ninh Bình', 'Thái Bình': 'Hưng Yên',
    'Bắc Giang': 'Bắc Ninh', 'Hải Dương': 'Hải Phòng',
    'Lai Châu': 'Điện Biên', 'Hà Giang': 'Tuyên Quang',
    'Yên Bái': 'Lào Cai', 'Bắc Kạn': 'Thái Nguyên',
    'Hòa Bình': 'Phú Thọ', 'Vĩnh Phúc': 'Phú Thọ',
    'Quảng Bình': 'Quảng Trị', 'Kon Tum': 'Quảng Ngãi',
    'Bình Định': 'Gia Lai', 'Phú Yên': 'Đắk Lắk',
    'Ninh Thuận': 'Khánh Hòa', 'Bình Thuận': 'Lâm Đồng',
    'Đắk Nông': 'Lâm Đồng', 'Long An': 'Tây Ninh',
    'Tiền Giang': 'Đồng Tháp', 'Bến Tre': 'Vĩnh Long',
    'Trà Vinh': 'Vĩnh Long', 'Sóc Trăng': 'Cần Thơ',
    'Hậu Giang': 'Cần Thơ', 'Kiên Giang': 'An Giang',
    'Bạc Liêu': 'Cà Mau', 'Bình Dương': 'Hồ Chí Minh',
    'Bà Rịa - Vũng Tàu': 'Hồ Chí Minh',
}


def fetch_poly(name, refresh=False):
    """-> list of rings [[ [lng,lat], ... ]] (outer rings only) or None."""
    cache = {}
    if os.path.exists(POLY) and not refresh:
        cache = json.load(open(POLY, encoding='utf-8'))
    if name in cache:
        return cache[name]
    for q in (f'{name}, Việt Nam', f'Tỉnh {name}, Việt Nam',
              f'Thành phố {name}, Việt Nam'):
        url = ('https://nominatim.openstreetmap.org/search?'
               + urllib.parse.urlencode({'q': q, 'format': 'json',
                                         'polygon_geojson': 1, 'limit': 1}))
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                j = json.load(r)
        except Exception as e:                                  # noqa: BLE001
            print(f'  {name}: {type(e).__name__}', file=sys.stderr)
            j = []
        time.sleep(1.1)                       # Nominatim: max 1 request/s
        if j and j[0].get('geojson'):
            g = j[0]['geojson']
            if g['type'] == 'Polygon':
                rings = [g['coordinates'][0]]
            elif g['type'] == 'MultiPolygon':
                rings = [p[0] for p in g['coordinates']]
            else:
                continue
            cache[name] = rings
            json.dump(cache, open(POLY, 'w'), ensure_ascii=False)
            return rings
    cache[name] = None
    json.dump(cache, open(POLY, 'w'), ensure_ascii=False)
    return None


def in_ring(x, y, ring):
    hit, n = False, len(ring)
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[(i + 1) % n][0], ring[(i + 1) % n][1]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--refresh', action='store_true')
    ap.add_argument('--by-source', action='store_true')
    a = ap.parse_args()

    polys, boxes = {}, {}
    for name in PROVINCES:
        rings = fetch_poly(name, a.refresh)
        if not rings:
            print(f'!! no polygon for {name}', file=sys.stderr)
            continue
        polys[name] = rings
        xs = [p[0] for r in rings for p in r]
        ys = [p[1] for r in rings for p in r]
        boxes[name] = (min(xs), min(ys), max(xs), max(ys))

    # absorbed provinces: match them, but count towards the surviving name
    for old, new in ABSORBED.items():
        rings = fetch_poly(old, a.refresh)
        if not rings:
            print(f'!! no polygon for {old}', file=sys.stderr)
            continue
        polys[old] = rings
        xs = [p[0] for r in rings for p in r]
        ys = [p[1] for r in rings for p in r]
        boxes[old] = (min(xs), min(ys), max(xs), max(ys))
    ALIAS = dict(ABSORBED)

    cams = json.load(open(DB, encoding='utf-8'))['cameras']
    print(f'cameras in DB: {len(cams)}   provinces with a polygon: {len(polys)}')

    counts = collections.Counter()
    by_src = collections.defaultdict(collections.Counter)
    unassigned = []
    for c in cams:
        x, y = c['lng'], c['lat']
        hit = None
        for name, (x0, y0, x1, y1) in boxes.items():
            if not (x0 <= x <= x1 and y0 <= y <= y1):
                continue
            if any(in_ring(x, y, r) for r in polys[name]):
                hit = name
                break
        if hit:
            hit = ALIAS.get(hit, hit)
            counts[hit] += 1
            by_src[hit][c.get('source', 'osm')] += 1
        else:
            unassigned.append(c)

    print(f'\n{"tỉnh":22s} {"tổng":>7s}', end='')
    if a.by_source:
        print(f'  {"vietmap":>8s} {"waze":>6s} {"police":>7s} {"kiemtra":>8s}',
              end='')
    print()
    for name, n in counts.most_common():
        print(f'{name:22s} {n:7d}', end='')
        if a.by_source:
            s = by_src[name]
            print(f'  {s["vietmap"]:8d} {s["waze"]:6d} {s["police"]:7d} '
                  f'{s["kiemtraphatnguoi"]:8d}', end='')
        print()
    print(f'\n{"không xác định":22s} {len(unassigned):7d}')
    print(f'{"TỔNG":22s} {sum(counts.values()) + len(unassigned):7d}')
    if unassigned:
        print('\nvài điểm không khớp polygon (kiểm tra tay):')
        for c in unassigned[:5]:
            print(f"  {c['lat']:.4f},{c['lng']:.4f}  {c.get('source')}  "
                  f"{(c.get('name') or '')[:40]}")


if __name__ == '__main__':
    main()
