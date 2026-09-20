#!/usr/bin/env python3
"""What did the *real* drive record around a given point?

Used to check the emulator replay: the app parked at one spot and showed
30 / CITY (a `service` way from the offline graph), so this prints what the
recorded drive had at the same coordinates — i.e. whether 30 is truth or an
artifact of the graph's nearest-way match.

    python3 tool/park_probe.py TRIP.json LAT LON [--near 5]
"""

from __future__ import annotations

import argparse
import json
import math
import sys


def meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip')
    ap.add_argument('lat', type=float)
    ap.add_argument('lon', type=float)
    ap.add_argument('--near', type=int, default=5)
    a = ap.parse_args()

    with open(a.trip, encoding='utf-8') as fh:
        trip = json.load(fh)
    locs = trip.get('locations') or []
    if not locs:
        print('no fixes in', a.trip, file=sys.stderr)
        return 2

    tgt = (a.lat, a.lon)
    ranked = sorted(
        ((meters((p['latitudeE7'] / 1e7, p['longitudeE7'] / 1e7), tgt), p)
         for p in locs),
        key=lambda x: x[0],
    )

    print(f'{a.trip}  ({len(locs)} fixes)')
    print(f'== nearest {a.near} fixes to {a.lat:.6f},{a.lon:.6f} ==')
    for d, p in ranked[:a.near]:
        print(f'  {d:7.1f} m  street={p.get("street")!r:24} '
              f'highway={p.get("highway")!r:12} '
              f'limit={p.get("speedLimit")} eff={p.get("limitEffective")} '
              f'src={p.get("limitSource")} v={p.get("velocity")}')

    last = locs[-1]
    print('== last fix of the drive ==')
    print(f'  street={last.get("street")!r} highway={last.get("highway")!r} '
          f'limit={last.get("speedLimit")} eff={last.get("limitEffective")} '
          f'src={last.get("limitSource")}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
