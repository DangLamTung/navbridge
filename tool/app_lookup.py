#!/usr/bin/env python3
"""Replicate the app's OWN lookup chain and explain every mismatch.

`speedLimitAt()` tries, in order:
    1. the Waze per-SEGMENT layer   (nearest within 25 m, fwd/rev by heading)
    2. the Waze POINT layer         (posted signs, nearest within 25 m)
    3. the VietMap E-DOG point layer
and returns null only if all three have nothing — in which case the app falls
back to the road's statutory class default.

My earlier check only looked at layer 1, so "the chip said 60 while a 50
segment existed" could be wrong: if the segment lookup misses (position!), the
answer may legitimately come from layer 2/3, or from nowhere.

For every fix of the given trips this prints the chain's answer at the logged
position and classifies the mismatch:

    OK-CHAIN   the chip equals what the chain returns   (not a mismatch at all)
    NO-DATA    the chain has nothing -> the class default was the only source
    MISSED     the chain HAS a value, the chip showed the class default instead
    SIGN       the chip came from a speed SIGN (limitSource='sign')
    OTHER      anything else

Usage: python3 tool/app_lookup.py [trips-dir]
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trips', nargs='?', default='docs/trips/device')
    ap.add_argument('--vehicle', default='motorbike')
    args = ap.parse_args()

    segs = T.Segments(A + 'waze_segments.bin')
    waze = T.PointIndex(T.load_speed_points(A + 'waze_speed_limits.json'))
    vm = T.PointIndex(T.load_speed_points(A + 'vietmap_speed_limits.json'))

    def chain(lat, lng, heading):
        kmh, street, cls, sep, dist, sid = segs.query(lat, lng, heading, MAX_M)
        if kmh:
            return kmh, 'segment', street
        pt, pd = waze.nearest(lat, lng)
        if pt and pd <= MAX_M:
            return pt['kmh'], 'waze-point', ''
        pt, pd = vm.nearest(lat, lng)
        if pt and pd <= MAX_M:
            return pt['kmh'], 'vietmap-point', ''
        return 0, 'none', ''

    files = sorted(glob.glob(os.path.join(REPO, args.trips, '2026-09-20*.json')))
    kind = collections.Counter()
    rows = []
    for path in files:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
        for e in doc.get('locations') or []:
            chip = e.get('limitEffective')
            if not chip or not e.get('latitudeE7'):
                continue
            lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
            h = e.get('heading')
            h = h if isinstance(h, (int, float)) else None
            hw = e.get('highway') or 'unclassified'
            cls = T.effective_limit(hw, args.vehicle, tagged_kmh=0)
            got, layer, street = chain(lat, lng, h)
            src = e.get('limitSource') or '?'
            if got and chip == got:
                k = 'OK-CHAIN'
            elif not got and chip == cls:
                k = 'NO-DATA'
            elif got and chip == cls and src == 'road':
                k = 'MISSED'
            elif src == 'sign':
                k = 'SIGN'
            else:
                k = 'OTHER'
            kind[k] += 1
            if k in ('MISSED', 'OTHER', 'SIGN'):
                rows.append((k, (e.get('timestamp') or '')[11:19],
                             e.get('street') or '', hw, chip, src, got, layer,
                             street, int(h) if h is not None else None))

    tot = sum(kind.values())
    print(f'{len(files)} trips · {tot} fixes with a chip value')
    for k, n in kind.most_common():
        print(f'  {k:<9} {n:>5} ({100.0 * n / max(1, tot):.1f}%)')
    print('\n--- MISSED: the chain has a value, the chip showed the class default'
          ' (the real bug) ---')
    miss = [r for r in rows if r[0] == 'MISSED']
    by_street = collections.Counter((r[2], r[3], r[4], r[6], r[7]) for r in miss)
    for (street, hw, chip, got, layer), n in by_street.most_common(20):
        print(f'  {n:>4}  {street[:24]:<25} {hw:<12} chip {chip} vs '
              f'{layer} {got}')
    print('\n--- SIGN: the chip came from a speed sign ---')
    sign = [r for r in rows if r[0] == 'SIGN']
    by_ss = collections.Counter((r[2], r[4], r[6], r[7]) for r in sign)
    for (street, chip, got, layer), n in by_ss.most_common(12):
        print(f'  {n:>4}  {street[:24]:<25} sign {chip} vs {layer} {got}')
    print('\n--- OTHER ---')
    for r in [r for r in rows if r[0] == 'OTHER'][:15]:
        print(f'  {r[1]} {r[2][:20]:<21} {r[3]:<12} chip {r[4]} ({r[5]}) vs '
              f'{r[7]} {r[6]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
