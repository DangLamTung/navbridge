#!/usr/bin/env python3
"""Waze-mod SIMULATION: what the app decided, fix by fix, against what Waze says.

`waze_mod_compare.py` compares khu dân cư BOUNDARIES. This compares the SPEED
LIMIT the app carried at every single fix — the question behind "chỗ 60 thì m
bảo 50" — using the recorded trip's own per-fix decision fields:

    speedLimit      the road's own value the app adopted (layer/OSM/class)
    limitEffective  the number the driver actually saw / was held to
    limitSource     'segment' | 'road' | 'sign' | 'city' | 'class' …
    limitLayer      which layer produced speedLimit

against the raw Waze Map Editor crawl (Decode_Waze/vn_features), queried at the
same position with the same heading, so the reference cannot inherit a bug from
the packed blob.

Bike mapping for the reference (VN law, what the app targets): the WME number is
the CAR limit. 65–85 on a two-way road is the 80 car / 60 bike pair; ≥ 90 only
exists on a divided road (bike 70). Values ≤ 60 are already the bike limit.

Usage
    python3 tool/waze_mod_sim.py --trip "$TMPDIR/sim_side.json" --gps build/web/trips/sim_2510.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tool'))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'wmc', os.path.join(ROOT, 'tool', 'waze_mod_compare.py'))
wmc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wmc)


def bike_from_car(kmh: int, divided: bool = False) -> int:
    """The bike limit that CAR limit implies (TT31/2019 + the app's own tables).

    Outside a built-up area: car 80 on a two-way road ⇒ bike 60, car 90 on a
    divided one ⇒ bike 70. Inside: car 60 exists on a road with a median, where
    the bike is also 60; on a two-way town street the same car 60 pairs with a
    bike 50. Anything posted at 50 or below is an explicit sign and is kept …
    except that the app cannot go below 50 for a bike unless a plate says so,
    which is where a Waze 40 is a real miss.
    """
    if kmh <= 0:
        return 0
    if kmh <= 60:
        return kmh
    if kmh <= 85:
        return 60
    return 70


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trip', required=True)
    ap.add_argument('--gps', required=True)
    ap.add_argument('--step', type=int, default=1, help='sample every Nth fix')
    ap.add_argument('--root', default=wmc.WME_ROOT)
    ap.add_argument('--show', type=int, default=15, help='rows of the worst list')
    args = ap.parse_args()

    trip = json.load(open(args.trip))
    locs = trip['locations']
    pts = [(l['latitudeE7'] / 1e7, l['longitudeE7'] / 1e7) for l in locs]
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + wmc.hav_m(pts[i - 1], pts[i]))

    mod = wmc.Mod(args.root)
    rows = []
    unknown = 0
    for i in range(0, len(locs), args.step):
        l = locs[i]
        if l.get('speedLimit') is None and l.get('limitEffective') is None:
            continue
        h = wmc.bearing(pts[max(0, i - 3)], pts[min(len(pts) - 1, i + 3)])
        v, street, _d, _how = mod.query(pts[i][0], pts[i][1], h)
        if v == 0:
            unknown += 1
            continue
        rows.append({
            'km': cum[i] / 1000.0,
            'waze': v,
            'bike': bike_from_car(v, bool(l.get('divided'))),
            'app_road': l.get('speedLimit') or 0,
            'app_eff': l.get('limitEffective') or 0,
            'src': l.get('limitSource') or '?',
            'layer': l.get('limitLayer') or '?',
            'urban': bool(l.get('urban')),
            'street': street or l.get('street') or '',
            'waze_street': street or '',
        })

    n = len(rows)
    if not n:
        raise SystemExit('no comparable fixes')
    total_km = cum[-1] / 1000.0
    print(f'{total_km:.1f} km | {len(locs)} fix | so được {n} '
          f'({unknown} fix WME không có dữ liệu)\n')

    same_road = sum(1 for r in rows if r['app_road'] == r['waze'])
    same_eff = sum(1 for r in rows if r['app_eff'] == r['bike'])
    over = sum(1 for r in rows if r['app_eff'] > r['bike'])
    under = sum(1 for r in rows if r['app_eff'] < r['bike'])
    print('so với WAZE MOD (giá trị xe con dưới bánh xe):')
    print(f'  speedLimit của app == WME          : {same_road:6d}/{n}  '
          f'({same_road/n*100:5.1f} %)')
    print(f'  limitEffective == mức xe máy đúng  : {same_eff:6d}/{n}  '
          f'({same_eff/n*100:5.1f} %)')
    print(f'  app CAO hơn mức đúng               : {over:6d}  '
          f'({over/n*100:5.1f} %)')
    print(f'  app THẤP hơn mức đúng              : {under:6d}  '
          f'({under/n*100:5.1f} %)\n')

    def bucket(r):
        d = r['app_eff'] - r['bike']
        return f"{r['app_eff']} vs {r['bike']} ({d:+d})"

    c = Counter(bucket(r) for r in rows if r['app_eff'] != r['bike'])
    print('các cặp lệch hay gặp (app vs đúng):')
    for k, v in c.most_common(10):
        print(f'  {k:22s} {v:5d} fix')

    print('\nnguồn của giá trị app dùng, khi lệch:')
    src = Counter(f"{r['src']}/{r['layer']}" for r in rows if r['app_eff'] != r['bike'])
    for k, v in src.most_common(8):
        print(f'  {k:26s} {v:5d} fix')

    # worst stretches, grouped into 1 km buckets so one bad junction is one row
    bad = defaultdict(int)
    kmb = defaultdict(float)
    for r in rows:
        if r['app_eff'] == r['bike']:
            continue
        b = (math.floor(r['km']), r['waze'], r['bike'], r['app_eff'])
        bad[b] += 1
        kmb[b] = r['km']
    print(f'\n{len(bad)} đoạn 1 km có lệch — nặng nhất {args.show}:')
    print('  km     WME  đúng  app  fix  đường')
    for b, cnt in sorted(bad.items(), key=lambda kv: -kv[1])[:args.show]:
        km0, waze, bike, app = b
        street = next((r['waze_street'] or r['street'] for r in rows
                       if math.floor(r['km']) == km0 and r['app_eff'] == app), '')
        print(f'  {kmb[b]:6.1f} {waze:4d} {bike:5d} {app:4d} {cnt:4d}  {street}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
