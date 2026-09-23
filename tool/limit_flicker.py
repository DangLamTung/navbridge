#!/usr/bin/env python3
"""How often does the displayed limit flip while the car stays on ONE road?

Waze carries parallel records for a single road, sometimes with different
spellings AND different posted values. Measured on the 2026-09-22 18:03 drive,
on Cộng Hòa:

    d=3.0 m  id=601376  fwd=60 rev=60  'Cộng Hòa'
    d=5.5 m  id=603315  fwd=50 rev=50  'Cộng Hoà'

The nearest record alternates with GPS noise, so the chip swapped 60/50 every
second (log: `waze limit=60 -> 60 (was 50)`, `50 -> 50 (was 60)`, `60 -> 60
(was 50)` inside 14 s) while the driver never left the road.

A flip counts only when the ROAD does not change (`same_road`, diacritic- and
word-insensitive) — a limit change when the car moves onto another street is a
correct, wanted update and is not counted. Flips are reported per road with
their duration, and the "1-fix flip" count (a value that changes for a single
fix and comes back) is the signature of the defect.

    python3 tool/limit_flicker.py TRIP.json [TRIP.json ...]
    python3 tool/limit_flicker.py --logcat file.txt   # the live ROAD: lines
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app_rules import same_road  # noqa: E402


def limit(rec: dict):
    v = rec.get('limitEffective')
    return v if v is not None else rec.get('speedLimit')


def flips_of(rows: list[dict]):
    """(same-road flips, 1-fix flips, per-road counter, episodes)."""
    flips = single = 0
    per_road = Counter()
    episodes = []
    for i in range(1, len(rows) - 1):
        a, b, c = rows[i - 1], rows[i], rows[i + 1]
        la, lb, lc = limit(a), limit(b), limit(c)
        if la is None or lb is None:
            continue
        if la == lb:
            continue
        road_a, road_b = a.get('street') or '', b.get('street') or ''
        if not road_a or not road_b or not same_road(road_a, road_b):
            continue  # a real road change: the limit change is wanted
        flips += 1
        per_road[road_b] += 1
        if lc is not None and lc == la:
            single += 1
        episodes.append((b.get('timestamp', '')[11:19], road_a, la, lb,
                         a.get('limitLayer'), b.get('limitLayer')))
    return flips, single, per_road, episodes


def report(path: str) -> None:
    with open(path, encoding='utf-8') as fh:
        rows = [r for r in json.load(fh)['locations'] if r.get('latitudeE7')]
    flips, single, per_road, episodes = flips_of(rows)
    print(f'{os.path.basename(path)[:26]:28} {len(rows):>4} fixes   '
          f'same-road flips {flips:>4}   of which 1-fix {single:>4}')
    for road, n in per_road.most_common(4):
        print(f'      {n:>4}  {road}')
    for t, road, la, lb, sa, sb in episodes[:6]:
        print(f'        {t} {road!r} {la} -> {lb} (layer {sa} -> {sb})')


LOGCAT_RE = re.compile(r'ROAD: waze limit=(\d+) -> (\d+) \(was (\d+)\) '
                       r'street="([^"]*)"')


def from_logcat(path: str) -> None:
    """Count same-road alternations in the live decision lines."""
    seen = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = LOGCAT_RE.search(line)
            if m:
                seen.append((line[6:14], int(m.group(1)), int(m.group(3)),
                             m.group(4)))
    flips = 0
    per_road = Counter()
    for i in range(1, len(seen) - 1):
        _, lim_i, was_i, road_i = seen[i]
        _, lim_p, was_p, road_p = seen[i - 1]
        if lim_i == was_i:
            continue                      # nothing was shown differently
        if not same_road(road_i, road_p):
            continue
        flips += 1
        per_road[road_i] += 1
    print(f'{os.path.basename(path)[:26]:28} {len(seen):>4} layer decisions   '
          f'same-road limit flips {flips:>4}')
    for road, n in per_road.most_common(5):
        print(f'      {n:>4}  {road}')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--logcat', action='store_true',
                    help='treat the arguments as logcat dumps')
    a = ap.parse_args()
    for p in a.paths:
        if a.logcat:
            from_logcat(p)
        else:
            report(p)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
