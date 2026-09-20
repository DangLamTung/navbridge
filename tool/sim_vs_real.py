#!/usr/bin/env python3
"""Compare two trips fix-by-fix at the same coordinates.

Built to check an emulator replay against the recorded drive it was replayed
from: the GPS track is identical, so any difference in the logged
street/highway/limit comes from the app's own route snap and road lookups,
not from different input. Prints one row per (sim street, real street) pair.

    python3 tool/sim_vs_real.py SIM.json REAL.json
"""

from __future__ import annotations

import argparse
import json
import math


def latlon(p: dict) -> tuple[float, float]:
    return p['latitudeE7'] / 1e7, p['longitudeE7'] / 1e7


def meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sim')
    ap.add_argument('real')
    a = ap.parse_args()

    with open(a.sim, encoding='utf-8') as fh:
        sim = json.load(fh)['locations']
    with open(a.real, encoding='utf-8') as fh:
        real = json.load(fh)['locations']
    rp = [latlon(p) for p in real]

    pairs = []
    for p in sim:
        q = latlon(p)
        i = min(range(len(rp)), key=lambda k: meters(q, rp[k]))
        pairs.append((meters(q, rp[i]), p, real[i]))

    print(f'sim  {a.sim}  ({len(sim)} fixes)')
    print(f'real {a.real}  ({len(real)} fixes)')
    print(f'max coordinate gap over all sim fixes: '
          f'{max(g for g, _, _ in pairs):.2f} m')
    print()
    hdr = (f'{"gap":>5} {"sim street":22} {"sim hw":10} {"lim":>4} | '
           f'{"real street":22} {"real hw":10} {"lim":>4} {"n":>4}')
    print(hdr)
    print('-' * len(hdr))

    seen: dict[tuple, int] = {}
    first: dict[tuple, tuple] = {}
    for gap, s, r in pairs:
        key = (s.get('street'), s.get('highway'), s.get('speedLimit'),
               r.get('street'), r.get('highway'), r.get('speedLimit'))
        seen[key] = seen.get(key, 0) + 1
        first.setdefault(key, (gap, s, r))

    for key in sorted(seen, key=lambda k: -seen[k]):
        gap, s, r = first[key]
        print(f'{gap:5.1f} {str(s.get("street"))[:22]:22} '
              f'{str(s.get("highway"))[:10]:10} {str(s.get("speedLimit")):>4} | '
              f'{str(r.get("street"))[:22]:22} {str(r.get("highway"))[:10]:10} '
              f'{str(r.get("speedLimit")):>4} {seen[key]:>4}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
