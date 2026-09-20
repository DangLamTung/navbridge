#!/usr/bin/env python3
"""Diagnose the residual mismatches of an emulator run.

Question: are they GPS misalignment between the two runs, or the lookup picking
a different segment at the same place?

Method: for every mismatching device fix, print
  * the distance between the device fix and its matched dataset fix
    (≈0 ⇒ the two runs are at the SAME coordinates ⇒ not misalignment), and
  * EVERY segment within 30 m of that point, with its value and street.
If two segments with different values sit within the app's 25 m query radius,
the choice flips on a few metres — which is exactly what the app does
differently: it looks the limit up at the ROUTE-SNAPPED position
(`_refreshRoad(snapped)`) while the trip log records the RAW fix
(`_logFix(pos)`), and this offline reader uses the logged raw position.
"""
from __future__ import annotations

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from waze_segments import Segments, CELL_DEG  # noqa: E402

TRIP = 'docs/trips/device/2026-09-18_172234_Chuyến_đi.json'
DEVICE = 'docs/trips/device/2026-09-20_101008_emulator_replay_fixed.json'
A = 'assets/offline_map/'


def metres(lat0, lng0, lat1, lng1):
    return math.hypot((lat1 - lat0) * 111320.0,
                      (lng1 - lng0) * 111320.0 * math.cos(math.radians(lat0)))


def main() -> int:
    device = json.load(open(DEVICE, encoding='utf-8'))
    stem = os.path.splitext(os.path.basename(TRIP))[0]
    truth = json.load(open(f'docs/trip_truth_{stem}.json', encoding='utf-8'))
    tf = truth['fixes']
    segs = Segments(A + 'waze_segments.bin')

    print(f'device log : {DEVICE} ({len(device["locations"])} fixes)')
    print(f'dataset    : {len(tf)} fixes, ground truth = segments\n')

    rows, unknown = [], []
    for f in device['locations']:
        lat, lng = f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7
        best = min(tf, key=lambda t: metres(lat, lng, t['lat'], t['lng']))
        off = metres(lat, lng, best['lat'], best['lng'])
        got = f.get('limitEffective') or f.get('speedLimit') or None
        want = best['expected_limit'] or None
        if got == want or got is None:
            continue
        if want is None:
            # The reference run had no road info yet at this instant — the
            # device did. Not a disagreement, just a start-of-drive race.
            unknown.append((f, best, off))
            continue
        rows.append((f, best, off, lat, lng, got, want))

    print(f'{len(rows)} mismatching fixes, {len(unknown)} skipped as '
          f'"expected unknown" (reference had no road info yet)\n')
    for i, (f, best, off, lat, lng, got, want) in enumerate(rows):
        print(f'--- mismatch {i + 1}: device {got} km/h vs dataset {want} km/h')
        print(f'    device fix  {lat:.6f},{lng:.6f}  road={f.get("speedLimit")} '
              f'street={f.get("street")!r}')
        print(f'    dataset fix {best["lat"]:.6f},{best["lng"]:.6f}  '
              f'segment={best["segment_kmh"]} street={best["segment_street"]!r}')
        print(f'    distance between the two positions: {off:.1f} m '
              f'{"(SAME POINT — not GPS misalignment)" if off < 2 else ""}')
        # every segment within 30 m of the device fix — 3×3 window, like the
        # app's own query (a single cell misses segments across a boundary)
        cands = []
        gy = int(math.floor(lat / CELL_DEG))
        gx = int(math.floor(lng / CELL_DEG))
        seen = set()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for s in segs.grid.get((gy + dy, gx + dx), ()):
                    if s in seen:
                        continue
                    seen.add(s)
                    d = Segments._dist(lat, lng, segs.pts[s])
                    if d <= 30:
                        cands.append((d, segs.value(s), segs.street(s)))
        cands.sort()
        vals = {c[1] for c in cands if c[1]}
        print(f'    segments within 30 m: {len(cands)} → values {sorted(vals)}'
              f'{"  ← TWO different values ⇒ the pick flips on metres" if len(vals) > 1 else ""}')
        for d, v, st in cands[:4]:
            print(f'       {d:5.1f} m  {v:>3} km/h  {st!r}')
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main())
