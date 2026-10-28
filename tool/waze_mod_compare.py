#!/usr/bin/env python3
"""Diff the app's khu dân cư callouts against the raw WAZE MAP EDITOR (WME) crawl.

The app decides a zone change from `assets/offline_map/waze_segments.bin`, which
is a downsampled build of the WME crawl in `Decode_Waze/vn_features`. This tool
reads the **crawl itself** (`segments.objects[].fwdMaxSpeed/revMaxSpeed`, the
real per-direction posted limit) so the comparison cannot inherit a bug from the
packed blob.

Model of truth: on the driven line, a fix is "in KDC" when the WME segment under
it is ≤ 60 km/h for the direction of travel (a motorbike's in-town limit), and
"outside" when it is > 60. Unknown/pairless fixes are dropped. A band change has
to survive `--confirm` consecutive fixes before it counts as a boundary.

Then every boundary the app ANNOUNCED is matched to a modelled boundary within
`--tol-m`; the rest are missed / spurious.

Usage
    python3 tool/waze_mod_compare.py --trip "$TMPDIR/sim_2510_best.json" \
        --gps build/web/trips/sim_2510.json --km 176
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import re
import sys
from collections import defaultdict

M_PER_DEG_LAT = 111320.0
CELL = 0.002  # degrees, candidate lookup grid
WME_ROOT = '/Users/tungdl/Documents/Eink/Decode_Waze/vn_features'


def hav_m(a, b):
    if a[0] == b[0] and a[1] == b[1]:
        return 0.0
    dy = (b[0] - a[0]) * M_PER_DEG_LAT
    dx = (b[1] - a[1]) * M_PER_DEG_LAT * math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot(dx, dy)


def bearing(a, b):
    dy = b[0] - a[0]
    dx = (b[1] - a[1]) * math.cos(math.radians((a[0] + b[0]) / 2))
    return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0


def ang_diff(a, b):
    d = abs((a - b) % 360.0)
    return min(d, 360.0 - d)


def tile_name(lat, lng):
    return f'lon{math.floor(lng * 10) / 10:.2f}_lat{math.floor(lat * 10) / 10:.2f}.json'


class Mod:
    """Nearest WME segment per position, straight from the crawl tiles."""

    def __init__(self, root: str):
        self.root = root
        self.tiles: dict[str, dict] = {}
        self.far_segs = []  # segments of already-loaded tiles, for the cell index

    def _load(self, name: str):
        if name in self.tiles:
            return self.tiles[name]
        path = os.path.join(self.root, name)
        if not os.path.exists(path):
            self.tiles[name] = {'cells': {}, 'names': {}}
            return self.tiles[name]
        raw = json.load(open(path))
        streets = {s['id']: s.get('name') for s in raw.get('streets', {}).get('objects', [])}
        cells: dict[tuple[int, int], list] = defaultdict(list)
        for s in raw.get('segments', {}).get('objects', []):
            geom = (s.get('geometry') or {}).get('coordinates') or []
            if len(geom) < 2:
                continue
            pts = [(p[1], p[0]) for p in geom]  # (lat, lng)
            entry = (pts, s.get('fwdMaxSpeed') or 0, s.get('revMaxSpeed') or 0,
                     streets.get(s.get('primaryStreetID')) or '', s.get('roadType'))
            lats = [p[0] for p in pts]
            lngs = [p[1] for p in pts]
            for gy in range(math.floor(min(lats) / CELL), math.floor(max(lats) / CELL) + 1):
                for gx in range(math.floor(min(lngs) / CELL), math.floor(max(lngs) / CELL) + 1):
                    cells[(gy, gx)].append(entry)
        self.tiles[name] = {'cells': cells, 'names': streets}
        return self.tiles[name]

    def query(self, lat: float, lng: float, heading: float | None = None,
              max_m: float = 25.0):
        """(kmh, street, dist_m, how) of the segment the bike is on."""
        best = None
        for dlat in (-0.1, 0.0, 0.1):
            for dlng in (-0.1, 0.0, 0.1):
                t = self._load(tile_name(lat + dlat, lng + dlng))
                gy, gx = math.floor(lat / CELL), math.floor(lng / CELL)
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        for pts, fwd, rev, street, _cls in t['cells'].get((gy + dy, gx + dx), ()):
                            if not (min(p[0] for p in pts) - 0.001 <= lat <= max(p[0] for p in pts) + 0.001
                                    and min(p[1] for p in pts) - 0.001 <= lng <= max(p[1] for p in pts) + 0.001):
                                continue
                            for i in range(len(pts) - 1):
                                a, b = pts[i], pts[i + 1]
                                # project onto sub-segment
                                ay, ax = a
                                by, bx = b
                                vy, vx = by - ay, bx - ax
                                L2 = vy * vy + vx * vx
                                t_ = 0.0 if L2 == 0 else max(0.0, min(1.0, ((lat - ay) * vy + (lng - ax) * vx) / L2))
                                py, px = ay + t_ * vy, ax + t_ * vx
                                dist = hav_m((lat, lng), (py, px))
                                if dist > max_m:
                                    continue
                                if best is None or dist < best[0]:
                                    seg_b = bearing(a, b)
                                    flip = heading is not None and ang_diff(heading, seg_b) > 90
                                    if fwd == rev:
                                        v = fwd
                                    elif fwd == 0 or rev == 0:
                                        v = max(fwd, rev)
                                    else:
                                        v = rev if flip else fwd
                                    best = (dist, v, street, 'fwd' if not flip else 'rev')
        if best is None:
            return 0, '', None, ''
        return best[1], best[2], best[0], best[3]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trip', required=True, help='simulated trip JSON (has announcements)')
    ap.add_argument('--gps', required=True, help='trace JSON fed to the simulation')
    ap.add_argument('--km', type=float, default=0, help='truncate the route at this km')
    ap.add_argument('--confirm', type=int, default=3, help='fixes a band change must survive')
    ap.add_argument('--tol-m', type=float, default=400.0, help='match tolerance')
    ap.add_argument('--min-zone-m', type=float, default=250.0,
                    help='drop zones shorter than this (WME flickers on town edges)')
    ap.add_argument('--max-m', type=float, default=25.0, help='segment search radius')
    ap.add_argument('--root', default=WME_ROOT)
    args = ap.parse_args()

    locs = json.load(open(args.gps))['locations']
    pts = [(l['latitudeE7'] / 1e7, l['longitudeE7'] / 1e7) for l in locs]
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + hav_m(pts[i - 1], pts[i]))
    if args.km:
        end = args.km * 1000
        pts = pts[:sum(1 for c in cum if c <= end)]
        cum = cum[:len(pts)]

    mod = Mod(args.root)
    vals, streets = [], []
    for i, p in enumerate(pts):
        h = bearing(pts[max(0, i - 3)], pts[min(len(pts) - 1, i + 3)])
        v, st, _d, _how = mod.query(p[0], p[1], h, args.max_m)
        vals.append(v)
        streets.append(st)

    # band sequence with debounce
    band, pending, pend_n = None, None, 0
    truth = []  # (km, 'in'|'out')
    for i, v in enumerate(vals):
        b = None if v == 0 else ('in' if v <= 60 else 'out')
        if b is None:
            continue
        if b == band:
            pending, pend_n = None, 0
            continue
        if b == pending:
            pend_n += 1
        else:
            pending, pend_n = b, 1
        if pend_n >= args.confirm:
            if band is not None:  # the first band is the starting state, not a boundary
                truth.append((cum[i] / 1000.0, b))
            band = b
            pending, pend_n = None, 0

    if args.min_zone_m:
        changed = True
        while changed and len(truth) > 1:
            changed = False
            for i in range(len(truth) - 1):
                if (truth[i + 1][0] - truth[i][0]) * 1000.0 < args.min_zone_m:
                    del truth[i:i + 2]
                    changed = True
                    break

    ann = [(a['time'][11:19], a['lat'], a['lng'], a['text'])
           for a in json.load(open(args.trip))['announcements']
           if a['kind'] == 'sign' and 'khu dân cư' in a['text'].lower()]
    # km of each callout: nearest fix
    def km_of(lat, lng):
        i = min(range(len(pts)), key=lambda i: hav_m((lat, lng), pts[i]))
        return cum[i] / 1000.0, hav_m((lat, lng), pts[i])
    calls = []
    outside = 0
    for t, la, ln, tx in ann:
        km, off = km_of(la, ln)
        if off > 150:  # callout is not on the simulated part of the route
            outside += 1
            continue
        calls.append((t, km, 'in' if 'bắt đầu' in tx.lower() and 'hết' not in tx.lower() else 'out', tx))

    print(f'route {cum[-1]/1000:.1f} km | {len(pts)} fix | WME seg hit '
          f'{sum(1 for v in vals if v)}/{len(vals)} | boundaries {len(truth)}')
    print(f'app callouts {len(calls)} on-route'
          + (f' (+{outside} off-route, not compared)' if outside else '') + '\n')
    print('  km   WME mod           app')
    print('  ---- ----------------- --------------------------------------')
    used = set()
    missed = 0
    for km, kind in truth:
        hit = [(i, c) for i, c in enumerate(calls)
               if c[2] == kind and abs(c[1] - km) * 1000 <= args.tol_m and i not in used]
        if hit:
            i, c = hit[0]
            used.add(i)
            print(f'  {km:6.1f} {kind:4s}  ✅ match    {c[0]} {c[1]:6.1f} {c[3]}')
        else:
            missed += 1
            near = [(abs(c[1] - km) * 1000, c) for c in calls if abs(c[1] - km) * 1000 <= args.tol_m * 3]
            near.sort()
            extra = f'  (gần nhất: {near[0][1][3]} @{near[0][1][1]:.1f} km, {near[0][0]:.0f} m)' if near else ''
            print(f'  {km:6.1f} {kind:4s}  ❌ MISS{extra}')
    for i, c in enumerate(calls):
        if i in used:
            continue
        print(f'  {c[1]:6.1f} ----  ⚠️  SPURIOUS  {c[0]} {c[3]}')
    print(f'\nmatched {len(used)}/{len(truth)} WME boundaries | missed {missed} | '
          f'spurious {len(calls) - len(used)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
