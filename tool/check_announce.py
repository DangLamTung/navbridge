#!/usr/bin/env python3
"""Check the SPEED-LIMIT ANNOUNCEMENTS of a recorded drive against the layer.

Prints three aligned timelines so "is the announcement right?" has an answer:

  1. WHAT THE APK SPOKE — the `announcements[]` a real device run logged, each
     placed on the route (metres from the start) with the road/segment value at
     that point.
  2. WHAT THE LAYER EXPECTS — limit changes from the ground truth through the
     app's own gate (value stable 2 s, never twice within 4 s).
  3. WHAT THE FIXED RULE COMPUTES — the app's per-fix effective limit + source.

Usage:
    python3 tool/check_announce.py <trip.json> [--vehicle motorbike]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

A = 'assets/offline_map/'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip')
    ap.add_argument('--vehicle', default='motorbike')
    args = ap.parse_args()

    truth = T.build(args.trip, A + 'vietnam_signs.json', args.vehicle,
                    A + 'waze_segments.bin', A + 'waze_speed_limits.json',
                    A + 'vietmap_speed_limits.json', verbose=False)
    fixes = truth['fixes']
    with open(args.trip, encoding='utf-8') as fh:
        doc = json.load(fh)

    print(f'--- 1. what the APK spoke ({os.path.basename(args.trip)}) ---')
    spoke = [a for a in doc.get('announcements', []) if a.get('kind') == 'limit']
    for a in spoke:
        t = int(a.get('timestampMs') or 0)
        f = min(fixes, key=lambda x: abs(x['tMs'] - t))
        print(f"  @{f['s_m']:>6.0f} m  {a.get('text')!r}   "
              f"(road={f['road_limit']} seg={f['segment_kmh']} "
              f"expect={f['expected_limit']}/{f['expected_source']})")
    if not spoke:
        print('  (none)')

    print('--- 2. what the layer expects ---')
    for e in truth['limit_events']:
        print(f"  @{e['s_m']:>6.0f} m  {e['limit']:>3} km/h ({e['source']})  "
              f"{e['text']!r}")

    print('--- 3. where the fixed rule changes the limit ---')
    prev = None
    for f in fixes:
        cur = (f['app_fixed_limit'], f['app_fixed_source'])
        if cur != prev:
            print(f"  @{f['s_m']:>6.0f} m  app {cur[0]:>3} ({cur[1]})   "
                  f"vs expected {f['expected_limit']:>3} "
                  f"({f['expected_source']})   seg={f['segment_kmh']}")
            prev = cur

    spoken_vals = [int(''.join(c for c in (a.get('text') or '') if c.isdigit())
                       .split(' ')[0] or 0) for a in spoke]
    print('--- verdict ---')
    print(f'  announcements spoken on device : {spoken_vals}')
    print(f'  expected                       : '
          f'{[e["limit"] for e in truth["limit_events"]]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
