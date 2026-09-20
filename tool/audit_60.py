#!/usr/bin/env python3
"""Why did the chip say 60 when the segment under the car says 50?

For every fix of the given trips where the DISPLAYED limit (`limitEffective`)
differs from the segment value read with the recorded heading, print what the
same segment stores for BOTH directions plus its street name, so the two
candidate causes can be told apart:

  * the app read the segment with a different heading (route bearing instead of
    the GPS heading) and got the other carriageway's value — Waze stores
    separate fwd/rev limits, and on a divided road they differ (50/60);
  * the app's lookup missed the segment entirely and kept the class default.

Usage: python3 tool/audit_60.py [trips-dir]
"""
from __future__ import annotations

import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEGS = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')


def main() -> int:
    trips = os.path.join(REPO, sys.argv[1] if len(sys.argv) > 1
                         else 'docs/trips/device')
    segs = T.Segments(SEGS)
    only = glob.glob(os.path.join(trips, '2026-09-20*.json'))

    buckets = collections.Counter()
    examples = {}
    for path in only:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
        for e in doc.get('locations') or []:
            chip = e.get('limitEffective')
            if not chip or not e.get('latitudeE7'):
                continue
            lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
            h = e.get('heading')
            h = h if isinstance(h, (int, float)) else None
            with_h = segs.query(lat, lng, h, 25)[0]
            no_h = segs.query(lat, lng, None, 25)[0]
            if with_h and chip == with_h:
                continue
            street = e.get('street') or '?'
            key = (chip, with_h, no_h, e.get('limitSource'), e.get('highway'),
                   street)
            buckets[key] += 1
            examples.setdefault(key, (lat, lng, h, e.get('accuracy')))

    print(f'trips scanned: {len(only)}')
    print('chip / seg(with heading) / seg(no heading) / source / class / street')
    for (chip, wh, nh, src, hw, street), c in buckets.most_common(22):
        lat, lng, h, acc = examples[(chip, wh, nh, src, hw, street)]
        flag = ''
        if nh and chip == nh and nh != wh:
            flag = '  ← chip == the HEADING-LESS read (other carriageway)'
        print(f'  {c:>4}  chip={chip:<3} seg_h={wh or 0:<3} seg_no_h={nh or 0:<3} '
              f'{str(src):<5} {str(hw):<13} {street[:22]:<23}'
              f'acc={acc} hdg={h}{flag}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
