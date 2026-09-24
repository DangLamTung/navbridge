#!/usr/bin/env python3
"""Audit what a maneuver callout says about SPEED.

The callout is "Đi trên Y, sau Nm, rẽ … vào X[ … vào Z]. Tốc độ tối đa K km/h."
It names the street(s) you turn INTO, so K must be the posted limit of one of
THOSE — not of Y, the street under the car. That was the bug the driver reported
(2026-09-24): "when announcement, the next street speed is not correct, still
taken from old street".

Method — no route geometry needed, the trip's own fixes are the track:
  1. the announcement is logged with the car's position, and the text says how far
     the maneuver is (N) → walk N metres along the recorded track to the junction;
  2. every street name in the sentence is looked up in the Waze segment layer
     (`assets/offline_map/waze_segments.bin`, the same reader the app uses) — the
     nearest segment carrying that name within 500 m of the junction;
  3. K is OK when it equals one of those streets' posted value, and OLD when it
     equals the value of Y instead.

`where the two disagree` is the honest headline: on streets where every candidate
is 50 km/h the number cannot prove which street it came from, so only the rows
where Y's value differs from the named street's value are falsifiable.

Usage:  python3 tool/announce_speed_audit.py docs/trips/device/<trip>.json …
        python3 tool/announce_speed_audit.py            # every 2026-09-2* device trip
"""
from __future__ import annotations

import glob
import json
import math
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from waze_segments import Segments  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEGS = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')

SAU = re.compile(r'sau ([\d.,]+) (ki lô mét|km|mét)')
SPOKEN = re.compile(r'Tốc độ tối đa (\d+) km/h')
ON = re.compile(r'Đi trên ([^,]+)')
INTO = re.compile(r'vào ([^,.]+)')
# words that follow "vào" without being a street name
STOP = {'vòng xuyến', 'ngã tư', 'ngã ba'}


def fold(s: str) -> str:
    s = unicodedata.normalize('NFD', s or '')
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return s.replace('đ', 'd').replace('Đ', 'D').lower().strip()


def metres(a, b) -> float:
    dy = (b[0] - a[0]) * 111320.0
    dx = (b[1] - a[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def parse_m(txt: str) -> float | None:
    m = SAU.search(txt)
    if not m:
        return None
    v = float(m.group(1).replace('.', '').replace(',', '.'))
    return v * 1000 if m.group(2) in ('ki lô mét', 'km') else v


class Layer:
    """Waze segment layer, indexed by folded street name."""

    def __init__(self) -> None:
        self.segs = Segments(SEGS)
        self.by_name: dict[str, list[int]] = {}
        for s in range(self.segs.n_segs):
            n = self.segs.street(s)
            if n and self.segs.pts[s]:
                self.by_name.setdefault(fold(n), []).append(s)

    def named(self, name: str, near, radius=500.0):
        """(kmh, dist_m) of the nearest segment called [name], or None."""
        best = None
        for s in self.by_name.get(fold(name), []):
            pts = self.segs.pts[s]
            for p in pts[:: max(1, len(pts) // 10)]:
                d = metres(near, p)
                if d <= radius and (best is None or d < best[1]):
                    best = (self.segs.value(s), d)
        return best

    def at(self, near):
        kmh, street, _c, _s, _d, _i = self.segs.query(near[0], near[1])
        return kmh, street


def run(path: str, layer: Layer):
    doc = json.load(open(path, encoding='utf-8'))
    fx = [(e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7, e)
          for e in (doc.get('locations') or []) if e.get('latitudeE7')]
    if len(fx) < 50:
        return None
    cum = [0.0]
    for i in range(1, len(fx)):
        cum.append(cum[-1] + metres(fx[i - 1][:2], fx[i][:2]))

    rows = []
    for a in doc.get('announcements') or []:
        txt = a.get('text') or ''
        sp, n = SPOKEN.search(txt), parse_m(txt)
        if not sp or not n or a.get('lat') is None:
            continue
        names = [m.strip() for m in INTO.findall(txt)
                 if fold(m.strip()) not in STOP]
        if not names:
            continue
        i = min(range(len(fx)),
                key=lambda k: metres((a['lat'], a['lng']), fx[k][:2]))
        t0 = cum[i] + n
        j = min(range(len(fx)), key=lambda k: abs(cum[k] - t0))
        mv = fx[j][:2]
        k = int(sp.group(1))
        named = [(nm, layer.named(nm, mv)) for nm in names]
        hit = [(nm, h) for nm, h in named if h and h[0] == k]
        on = ON.search(txt)
        rows.append((k, hit[0][0] if hit else None, named,
                     layer.at((a['lat'], a['lng'])),
                     (on.group(1).strip() if on else '')))
    if not rows:
        return None

    print('\n=== %s — %d callouts with a spoken limit'
          % (os.path.basename(path), len(rows)))
    good = old = disc = disc_ok = 0
    for k, nm, named, cur, on in rows:
        ok = nm is not None
        wrong_old = (not ok) and cur[0] == k
        good += ok
        old += wrong_old
        vals = [h[0] for _nm, h in named if h]
        if vals and cur[0] and min(vals) != cur[0]:
            disc += 1
            disc_ok += ok
        detail = ', '.join(
            '%s=%s%s' % (x[0][:20], (x[1][0] if x[1] else '-'),
                         '@%dm' % x[1][1] if x[1] else '') for x in named)
        print('   %s spoken %2d | names: %-52s | on %s=%s'
              % ('OK   ' if ok else ('OLD  ' if wrong_old else 'MISS '),
                 k, detail[:52], (on or '?')[:16], cur[0]))
    print('   -> quotes a street the sentence NAMES: %d/%d ; quotes the street '
          'under the car instead: %d/%d' % (good, len(rows), old, len(rows)))
    print('   -> where the two disagree (the falsifiable rows): %d/%d correct'
          % (disc_ok, disc))
    return good, old, len(rows)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        args = sorted(glob.glob(os.path.join(
            REPO, 'docs/trips/device/2026-09-2*.json')))
    layer = Layer()
    for p in args:
        try:
            run(p, layer)
        except Exception as e:  # noqa: BLE001
            print('  !', p, e)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
