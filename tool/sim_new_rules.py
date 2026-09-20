#!/usr/bin/env python3
"""What today's drive would read NOW, with the new decision chain.

Replays every fix of a recorded trip through the rules the app ships today and
prints the change against what the app actually showed:

  chain (raw fix first, then snapped-as-fallback is not needed offline):
     1. Waze SEGMENT under the car        -> that value is authority
     2. Waze posted-limit POINT           -> that value
     3. VietMap E-DOG posted-limit point  -> that value
     4. a speed SIGN within 30 m that is TIGHTER than the value above wins
     5. nothing anywhere -> POI-density built-up test: in town the built-up
        value (50; a one-way way counts as >=2 làn -> 60), else the class default

Usage: python3 tool/sim_new_rules.py [trips-dir] [--vehicle motorbike]
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = os.path.join(REPO, 'assets/offline_map/')
MAX_M = 25.0
SIGN_IN_FORCE_M = 30.0   # the sign counts as reached within kSignReachedM = 50,
                         # but a sign two streets away must not count — 30 m
POI_CELL = 0.01
POI_MIN = 25


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trips', nargs='?', default='docs/trips/device')
    ap.add_argument('--vehicle', default='motorbike')
    args = ap.parse_args()

    segs = T.Segments(A + 'waze_segments.bin')
    waze = T.PointIndex(T.load_speed_points(A + 'waze_speed_limits.json'))
    vm = T.PointIndex(T.load_speed_points(A + 'vietmap_speed_limits.json'))
    signs = [s for s in T.load_signs(A + 'vietnam_signs.json')
             if s['kind'] == 'speed' and s['value']]

    with open(A + 'vietnam_pois.json', encoding='utf-8') as fh:
        pois = json.load(fh)
    grid = collections.Counter()
    for cat in pois.values():
        for it in cat.get('items', []) if isinstance(cat, dict) else []:
            if it.get('lat') is None:
                continue
            grid[((int(float(it['lat']) / POI_CELL)) << 16)
                 | (int(float(it['lng']) / POI_CELL) & 0xFFFF)] += 1

    def urban(lat, lng):
        cy, cx = int(lat / POI_CELL), int(lng / POI_CELL)
        n = 0
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                n += grid.get(((cy + dy) << 16) | ((cx + dx) & 0xFFFF), 0)
        return n >= POI_MIN

    # speed signs bucketed for a quick "is one right here" test
    sign_grid = collections.defaultdict(list)
    for s in signs:
        sign_grid[(int(s['lat'] / 0.002), int(s['lng'] / 0.002))].append(s)

    def sign_near(lat, lng):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for s in sign_grid.get((int(lat / 0.002) + dy,
                                        int(lng / 0.002) + dx), ()):
                    if T.meters((lat, lng), (s['lat'], s['lng'])) <= SIGN_IN_FORCE_M:
                        return s['value']
        return None

    changes = collections.Counter()
    was60now50 = []
    old_dist = collections.Counter()
    new_dist = collections.Counter()
    for path in sorted(glob.glob(os.path.join(REPO, args.trips,
                                              '2026-09-20*.json'))):
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
        for e in doc.get('locations') or []:
            old = e.get('limitEffective')
            if not old or not e.get('latitudeE7'):
                continue
            lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
            h = e.get('heading')
            h = h if isinstance(h, (int, float)) else None
            hw = e.get('highway') or 'unclassified'

            v = segs.query(lat, lng, h, MAX_M)[0] or 0
            if not v:
                pt, pd = waze.nearest(lat, lng)
                v = pt['kmh'] if pt and pd <= MAX_M else 0
            if not v:
                pt, pd = vm.nearest(lat, lng)
                v = pt['kmh'] if pt and pd <= MAX_M else 0
            if v:
                s = sign_near(lat, lng)
                new = s if (s is not None and s < v) else v
            else:
                s = sign_near(lat, lng)
                if s is not None:
                    new = s
                elif urban(lat, lng):
                    new = 50          # built-up two-way / 1 lane
                else:
                    new = T.effective_limit(hw, args.vehicle, tagged_kmh=0)

            old_dist[old] += 1
            new_dist[new] += 1
            if new != old:
                changes[(old, new)] += 1
                if old == 60 and new == 50:
                    was60now50.append((e.get('street') or '?', hw))

    def show(name, c):
        print(f'  {name}: ' + ', '.join(f'{k}km/h×{v}' for k, v in
                                        sorted(c.items())))

    print('--- displayed limit, TODAY (as recorded) ---')
    show('old', old_dist)
    print('--- displayed limit, with the new chain ---')
    show('new', new_dist)
    print('\n--- changes (old → new) ---')
    for (o, n), c in changes.most_common(10):
        print(f'  {c:>5}  {o} → {n} km/h')
    print(f'\n--- streets that stop reading 60 ---')
    for street, c in collections.Counter(s for s, _ in was60now50).most_common(12):
        print(f'  {c:>5}  {street}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
