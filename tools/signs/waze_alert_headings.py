#!/usr/bin/env python3
"""Give the Waze camera layer the DIRECTION it always had.

The Waze Mod export keeps a `direction` per alert (`FWD` / `REV` / `BOTH`,
16 908 / 13 252 / 5 104 rows) relative to the node order of the segment the
alert sits on. The pipeline that built `vietnam_cameras.json` dropped it, so
every Waze camera was announced on BOTH carriageways — 156 of the 477 camera
hits on the 2026-10-24 drive were pointed the other way.

This script converts FWD/REV into a compass heading using the SEGMENT geometry
we already crawled (`Decode_Waze/vn_features/*.json`, 1 731 442 segments, and
35 249 of 35 264 alerts have their segment), then writes `heading` onto the
matching Waze camera rows. `BOTH` stays null (the camera really does watch both).

Usage:
    python3 tools/signs/waze_alert_headings.py [--write]
Without --write it only reports what it would change.
"""
from __future__ import annotations

import glob
import json
import math
import os
import sys

SRC = os.path.expanduser('~/Documents/Eink/Decode_Waze/vn_point_notices.tsv')
FEATURES = os.path.expanduser('~/Documents/Eink/Decode_Waze/vn_features/*.json')
CAM = os.path.join(os.path.dirname(__file__), '..', '..', 'assets',
                   'offline_map', 'vietnam_cameras.json')


def bearing(a, b) -> float:
    dy = b[1] - a[1]
    dx = (b[0] - a[0]) * math.cos(math.radians(a[1]))
    return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0


def main() -> int:
    write = '--write' in sys.argv
    segs: dict[int, list[tuple[float, float]]] = {}
    for f in glob.glob(FEATURES):
        doc = json.load(open(f, encoding='utf-8'))
        for s in doc.get('segments', {}).get('objects', []):
            g = (s.get('geometry') or {}).get('coordinates') or []
            pts = [(float(p[0]), float(p[1])) for p in g]
            if len(pts) >= 2:
                segs[s['id']] = pts
    print(f'segment geometries: {len(segs)}')

    want: dict[tuple[float, float], float] = {}
    both = 0
    for line in open(SRC, encoding='utf-8'):
        if line.startswith('#'):
            continue
        p = line.rstrip('\n').split('\t')
        if len(p) < 9:
            continue
        try:
            lat, lng, sid = float(p[4]), float(p[5]), int(p[7])
        except ValueError:
            continue
        d = p[8].strip()
        if d == 'BOTH':
            both += 1
            continue
        pts = segs.get(sid)
        if not pts:
            continue
        # nearest vertex → direction of the segment there, in node order
        best, bi = 1e18, 0
        for i, q in enumerate(pts):
            dy = (q[1] - lat) * 111320
            dx = (q[0] - lng) * 111320 * math.cos(math.radians(lat))
            dd = dy * dy + dx * dx
            if dd < best:
                best, bi = dd, i
        a = pts[max(0, bi - 1)]
        b = pts[min(len(pts) - 1, bi + 1)]
        brg = bearing(a, b)
        if d == 'REV':
            brg = (brg + 180.0) % 360.0
        want[(round(lat, 5), round(lng, 5))] = round(brg)

    print(f'alerts with a heading: {len(want)}, BOTH (left null): {both}')

    doc = json.load(open(CAM, encoding='utf-8'))
    cams = doc['cameras']
    changed = 0
    for c in cams:
        if c.get('source') != 'waze':
            continue
        h = want.get((round(c['lat'], 5), round(c['lng'], 5)))
        if h is None:
            continue
        if c.get('heading') != h:
            c['heading'] = h
            changed += 1
    print(f'waze cameras patched: {changed}')
    if write:
        doc['generated'] = '2026-10-24 (Waze cameras carry their own heading)'
        json.dump(doc, open(CAM, 'w', encoding='utf-8'),
                  ensure_ascii=False, separators=(',', ':'))
        print('written', CAM)
    else:
        print('dry run — pass --write to apply')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
