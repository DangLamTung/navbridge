#!/usr/bin/env python3
"""Where does the app read 60 km/h on a road the segment layer calls 50?

The user's report: "60 on 2 lanes no phân cách" (a two-way street with no dải
phân cách is legally 50 inside a built-up area) and "the speed change is too
slow".

Every recorded device trip logs, per fix, the value the ROAD layer produced
(`speedLimit`) and the OSM class (`highway`). Comparing that with the Waze
segment under the same fix says which of the two candidate rules produced the
60:

  A. `highway` residential/unclassified -> urbanLimit(oneway, lanes, divided):
     60 requires `divided` (an opposite-way carriageway of the same street
     within ~35 m) or `oneway=true && (lanes ?? 2) >= 2`.
  B. any other class -> the statutory class default, where secondary = 60 and
     tertiary = 50, with no built-up cap any more (the boundary layer that used
     to supply it was removed).

Usage: python3 tool/why_60.py [--trips docs/trips/device]
"""
from __future__ import annotations

import argparse
import collections
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

SEGS = 'assets/offline_map/waze_segments.bin'
BUILT_UP = ('residential', 'unclassified')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--trips', default='docs/trips/device')
    args = ap.parse_args()

    segs = T.Segments(SEGS)
    files = sorted(f for f in glob.glob(os.path.join(args.trips, '*.json'))
                   if 'emulator' not in os.path.basename(f))

    hot60 = collections.Counter()      # road layer says 60, segment says 50
    hot50 = collections.Counter()      # road layer says 50, segment says 60
    rule = collections.Counter()
    named = collections.Counter()
    no_seg = collections.Counter()
    totals = collections.Counter()

    for path in files:
        _meta, fixes = T.load_trip(path)
        for f in fixes:
            road = f['road_limit']
            if not road:
                continue
            hw = f['highway'] or 'unknown'
            heading = f['heading'] if isinstance(f['heading'], (int, float)) \
                else None
            kmh = segs.query(f['lat'], f['lng'], heading, 25)[0]
            totals['fixes'] += 1
            totals[f'road={road}'] += 1
            if road == 60 and kmh == 50:
                hot60[(hw, f['street'] or '?')] += 1
                rule['A built-up class rule' if hw in BUILT_UP
                     else 'B class default'] += 1
                named[f['street'] or '?'] += 1
            elif road == 50 and kmh == 60:
                hot50[(hw, f['street'] or '?')] += 1
            elif not kmh:
                no_seg[hw] += 1

    n = max(1, totals['fixes'])
    print(f'{len(files)} trips, {totals["fixes"]} fixes with a logged road value')
    print('  road value distribution: '
          + ', '.join(f'{k.split("=")[1]}km/h×{v}'
                      for k, v in sorted(totals.items())
                      if k.startswith('road=')))
    print(f'\n--- road layer 60 while the segment says 50: {sum(hot60.values())} '
          f'fixes ({100.0 * sum(hot60.values()) / n:.1f}%) ---')
    print(f'  rule that produced it: {dict(rule)}')
    for (hw, street), c in hot60.most_common(12):
        print(f'    {c:>4}  {hw:<14} {street}')
    print(f'\n--- road layer 50 while the segment says 60: {sum(hot50.values())} '
          f'fixes ({100.0 * sum(hot50.values()) / n:.1f}%) ---')
    for (hw, street), c in hot50.most_common(6):
        print(f'    {c:>4}  {hw:<14} {street}')
    print(f'\n--- no segment within 25 m (value came from the graph/class): '
          f'{sum(no_seg.values())} fixes {dict(no_seg.most_common(6))}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
