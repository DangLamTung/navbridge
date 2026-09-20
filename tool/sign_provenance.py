#!/usr/bin/env python3
"""Where do the speed SIGN points that contradict the segment layer come from?

Finds the fixes where the app's limit came from a sign (`limitSource == 'sign'`)
and the segment under the car said something else, then lists every `kind=speed`
entry of the bundled sign index within a radius of those spots — with its
`source` field (osm / vietmap / waze) and the segment value underneath it, so
the provenance of a bad sign is visible instead of guessed.

Usage: python3 tool/sign_provenance.py [trips-dir] [--radius 400]
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trips', nargs='?', default='docs/trips/device')
    ap.add_argument('--radius', type=float, default=400.0)
    args = ap.parse_args()

    segs = T.Segments(A + 'waze_segments.bin')
    signs = [s for s in T.load_signs(A + 'vietnam_signs.json')
             if s['kind'] == 'speed' and s['value']]
    print(f'speed signs in the index: {len(signs)}')
    src_all = collections.Counter(s['source'] or '(none)' for s in signs)
    print(f'  by source field: {dict(src_all)}')

    # spots where the app used a SIGN while the segment disagreed
    spots = []
    for path in sorted(glob.glob(os.path.join(REPO, args.trips,
                                              '2026-09-20*.json'))):
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
        for e in doc.get('locations') or []:
            if e.get('limitSource') != 'sign' or not e.get('latitudeE7'):
                continue
            lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
            h = e.get('heading')
            kmh = segs.query(lat, lng,
                             h if isinstance(h, (int, float)) else None, 25)[0]
            if kmh and kmh != e.get('limitEffective'):
                spots.append((lat, lng, e.get('limitEffective'), kmh,
                              e.get('street') or ''))
    print(f'\nfixes where a SIGN governed and the segment disagreed: {len(spots)}')
    by_street = collections.Counter((s[4], s[2], s[3]) for s in spots)
    for (street, chip, seg), n in by_street.most_common(8):
        print(f'  {n:>4}  {street[:24]:<25} sign {chip} vs segment {seg}')

    print('\n--- the sign points themselves ---')
    seen = set()
    for (lat, lng, chip, seg, street) in spots:
        for s in signs:
            if T.meters((lat, lng), (s['lat'], s['lng'])) > args.radius:
                continue
            key = (round(s['lat'], 5), round(s['lng'], 5), s['value'])
            if key in seen:
                continue
            seen.add(key)
            d = T.meters((lat, lng), (s['lat'], s['lng']))
            under = segs.query(s['lat'], s['lng'], None, 25)
            print(f'  {d:>6.0f} m from the car · sign {s["value"]} km/h · '
                  f'source={s["source"] or "(none)"} · name={s["name"][:28]!r} · '
                  f'segment under it: {under[0] or 0} {under[1] or ""}')
    if not seen:
        print('  (none within the radius — the sign came from a POINT layer, '
              'not the sign index)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
