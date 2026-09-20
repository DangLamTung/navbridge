#!/usr/bin/env python3
"""What the chip DISPLAYED vs the Waze segment layer, and how late it changed.

Two questions from real-device testing:
  1. "so many time it gives wrong speed, 60 on 2 lanes no phân cách"
     -> compare `limitEffective` (the number the driver sees) with the Waze
        segment under the same fix, grouped by `limitSource` ('sign' / 'road')
        and by street, so the mechanism is identified rather than assumed.
  2. "the speed change is too slow"
     -> whenever the segment layer's value changes, measure how many seconds
        and metres later the displayed value catches up.

Usage: python3 tool/display_vs_layer.py [--trips docs/trips]
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

SEGS = 'assets/offline_map/waze_segments.bin'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--trips', default='docs/trips')
    args = ap.parse_args()

    segs = T.Segments(SEGS)
    files = sorted(f for f in glob.glob(os.path.join(args.trips, '*.json'))
                   if 'emulator' not in os.path.basename(f))

    total = matched = mismatch = 0
    by_source = collections.Counter()
    streets = collections.Counter()
    unknown = 0
    lag_s: list[float] = []
    lag_m: list[float] = []
    never: collections.Counter = collections.Counter()

    for path in files:
        with open(path, encoding='utf-8') as fh:
            data = json.load(fh)
        locs = [l for l in data.get('locations', [])
                if l.get('limitEffective') and l.get('latitudeE7')]
        if not locs:
            continue
        seq = []
        for l in locs:
            lat, lng = l['latitudeE7'] / 1e7, l['longitudeE7'] / 1e7
            h = l.get('heading')
            kmh = segs.query(lat, lng,
                             h if isinstance(h, (int, float)) else None, 25)[0]
            seq.append({
                't': int(l.get('timestampMs') or 0) / 1000.0,
                'disp': int(l['limitEffective']),
                'src': l.get('limitSource') or '?',
                'seg': kmh,
                'street': l.get('street') or '?',
                'hw': l.get('highway') or '?',
            })
        for s in seq:
            total += 1
            if not s['seg']:
                continue
            if s['disp'] == s['seg']:
                matched += 1
            else:
                mismatch += 1
                by_source[(s['src'], s['disp'], s['seg'], s['hw'])] += 1
                if s['disp'] == 60 and s['seg'] == 50:
                    streets[s['street']] += 1
                if s['disp'] == 0:
                    unknown += 1
        # --- lag: segment changes -> when does the chip follow? -------------
        for i in range(1, len(seq)):
            prev, cur = seq[i - 1], seq[i]
            if not cur['seg'] or cur['seg'] == prev['seg']:
                continue
            want = cur['seg']
            if cur['disp'] == want:
                continue
            for j in range(i, min(i + 240, len(seq))):
                if seq[j]['seg'] != want:
                    break  # the layer moved on before the chip caught up
                if seq[j]['disp'] == want:
                    lag_s.append(seq[j]['t'] - cur['t'])
                    lag_m.append(seq[j].get('m', 0.0))
                    break
            else:
                never[f'{prev["seg"]}->{want}'] += 1

    n = max(1, total)
    print(f'{len(files)} trips, {total} fixes with a displayed limit')
    print(f'  chip == segment layer : {matched} ({100.0 * matched / n:.1f}%)')
    print(f'  chip != segment layer : {mismatch} ({100.0 * mismatch / n:.1f}%)'
          f'   [of which chip=unknown(0): {unknown}]')
    print('\n--- what the wrong value was, and where it came from ---')
    for (src, disp, seg, hw), c in by_source.most_common(10):
        print(f'  {c:>5}  chip={disp:<3} layer={seg:<3} source={src:<5} '
              f'class={hw}')
    print('\n--- streets where the chip said 60 and the layer says 50 ---')
    for street, c in streets.most_common(10):
        print(f'  {c:>5}  {street}')
    print(f'\n--- when the layer changed but the chip did not follow ---')
    if lag_s:
        lag_s.sort()
        print(f'  cases measured: {len(lag_s)}   median {statistics.median(lag_s):.1f}s, '
              f'p90 {lag_s[int(0.9 * (len(lag_s) - 1))]:.1f}s, '
              f'worst {lag_s[-1]:.1f}s')
    print(f'  never followed within 4 min: {sum(never.values())} '
          f'{dict(never.most_common(6))}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
