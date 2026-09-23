#!/usr/bin/env python3
"""Restore the precise coordinates of snapped sign rows, and their provenance.

TWO stories, both proven from the files on disk:

1. VIETMAP / E-DOG rows. `fix_vietmap_precision.py` (2026-09-18) repaired the
   cameras and the E-DOG sign kinds — but it repairs only rows whose
   `source == "vietmap"`, and most of the snapped E-DOG-derived rows are
   labelled `source: "osm"` (slow_down 2,941, toll_booth 1,449, populated_end
   780, railway_crossing 348, tunnel 186, populated 168). Matching a row to an
   E-DOG row in its own 0.001° cell PROVES where it came from, so the label is
   corrected and the coordinate rewritten at the same time.

2. WAZE point-notice rows. The turn signs are labelled `source: "vietmap"`, but
   the E-DOG dump carries NO turn types (only 1-10) — they came from the Waze
   decode, whose merge deduped on a ~100 m grid. That both lost the precision and
   MERGED DISTINCT SIGNS. One junction on QL3, Thái Nguyên:

     Waze TSV   16 no_left_turn  22.665712 106.256093
                16 no_left_turn  22.665709 106.257330  <- a second sign ~100 m on
                17 no_right_turn 22.665650 106.256956
     asset      no_left_turn  vietmap 22.666,106.256   <- both in one row
                no_right_turn vietmap 22.666,106.257

   `notes_combined.tsv` has 6-decimal coordinates, so those rows can be placed
   precisely again (speed 4,048 of 4,073 snapped rows, every turn kind 100%).

Rows that match NEITHER source keep their snapped coordinate: they are the ones
`offline_road_signs.dart` drops at load (`kMinSignDecimals`).

Usage:
    python3 tools/signs/repair_sign_coords.py            # dry run
    python3 tools/signs/repair_sign_coords.py --write     # backup + rewrite
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import shutil
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MAP = REPO / 'assets/offline_map'
ASSET = MAP / 'vietnam_signs.json'
EDOG = REPO / 'tools/data/vietmap_kc01/edog_data.txt'
WAZE = Path('/Users/tungdl/Documents/Eink/Decode_Waze/notes_combined.tsv')

EDOG_TYPE = {'no_passing': (5,), 'no_passing_end': (6,), 'slow_down': (7, 5),
             'toll_booth': (8, 6), 'tunnel': (9, 7), 'railway_crossing': (8,)}

# Kinds the app drops at load anyway (`droppedSignKinds`): repairing them would
# only shuffle dead rows, and their type codes COLLIDE between the two KC01
# tables (old 9 = populated vs new 9 = tunnel, old 10 = populated_end vs new
# 10 = speed camera), so a "repair" would move them onto a camera or a tunnel.
SKIP = {'populated', 'populated_end'}
WAZE_TYPE = {'populated': (26,), 'populated_end': (27,), 'no_passing': (14,),
             'no_passing_end': (15,), 'no_left_turn': (8, 16),
             'no_right_turn': (9, 17), 'no_u_turn': (11, 18),
             'no_left_uturn': (2, 5), 'no_right_uturn': (6, 7),
             'only_straight': (21,), 'only_right': (22,), 'only_left': (23,),
             'end_prohibitions': (35,), 'speed': (12, 13)}


def on_grid(v: float) -> bool:
    return abs(round(v, 6) * 1e6) % 1000 < 0.5


def metres(a, b) -> float:
    dy = (a[0] - b[0]) * 111320.0
    dx = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def load_edog():
    cells = collections.defaultdict(list)
    for line in open(EDOG, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if not line or line.startswith('#') or line.startswith('POINT'):
            continue
        f = line.split('\t')
        if len(f) < 4:
            continue
        try:
            lng, lat, t = int(f[0]) / 1e6, int(f[1]) / 1e6, int(f[2])
        except ValueError:
            continue
        cells[t].append((lat, lng))
    return cells


def load_waze():
    cells = collections.defaultdict(list)
    for i, line in enumerate(open(WAZE, encoding='utf-8', errors='replace')):
        f = line.rstrip('\n').split('\t')
        if i == 0 or len(f) < 5:
            continue
        try:
            t, lat, lng = int(f[1]), float(f[3]), float(f[4])
        except ValueError:
            continue
        cells[t].append((lat, lng))
    return cells


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--radius-m', type=float, default=60.0,
                    help='how far a source row may sit from the snapped cell')
    a = ap.parse_args()
    doc = json.load(open(ASSET, encoding='utf-8'))
    signs = doc['signs']
    edog = load_edog()
    waze = load_waze()

    stats = collections.Counter()
    moves = collections.defaultdict(list)
    for s in signs:
        lat, lng = s.get('lat'), s.get('lng')
        if lat is None or lng is None or not (on_grid(lat) and on_grid(lng)):
            stats['fine'] += 1
            continue
        if s['kind'] in SKIP:
            stats['skipped_kind'] += 1
            continue
        cell = (round(lat, 3), round(lng, 3))
        # 1) E-DOG wins when one of its rows for this kind sits in the cell.
        #    BOTH KC01 tables are tried: `build_vietmap.py` reads 2/3/5/6/7/8/9
        #    as populated/populated_end/no_passing/no_passing_end/slow_down/
        #    toll_booth/tunnel, while the older `merge_edog_vietmap.py` read
        #    5/6/7/8 as slow_down/toll_booth/tunnel/railway — both wrote into
        #    this asset (see tools/signs/check_edog_kind_mapping.py).
        best = []
        for t in EDOG_TYPE.get(s['kind'], ()):
            best += [p for p in edog.get(t, ())
                     if (round(p[0], 3), round(p[1], 3)) == cell]
        if best:
            near = min(best, key=lambda p: metres((lat, lng), p))
            if metres((lat, lng), near) <= a.radius_m:
                moves['edog'].append(metres((lat, lng), near))
                s['lat'], s['lng'] = near
                s['source'] = 'vietmap'
                stats['repaired_edog'] += 1
                continue
        # 2) Otherwise the Waze decode.
        types = WAZE_TYPE.get(s['kind'], ())
        best = []
        for t in types:
            best += [p for p in waze.get(t, ())
                     if (round(p[0], 3), round(p[1], 3)) == cell]
        if best:
            near = min(best, key=lambda p: metres((lat, lng), p))
            if metres((lat, lng), near) <= a.radius_m:
                moves['waze'].append(metres((lat, lng), near))
                s['lat'], s['lng'] = near
                s['source'] = 'waze'
                stats['repaired_waze'] += 1
                continue
        stats['unmatched'] += 1

    def med(v):
        if not v:
            return 0.0
        v = sorted(v)
        return v[len(v) // 2]

    print('signs: %d' % len(signs))
    print('  already precise      : %d' % stats['fine'])
    print('  repaired from E-DOG  : %d  (median move %.1f m, max %.1f m)'
          % (stats['repaired_edog'], med(moves['edog']),
             max(moves['edog'], default=0)))
    print('  repaired from WAZE   : %d  (median move %.1f m, max %.1f m)'
          % (stats['repaired_waze'], med(moves['waze']),
             max(moves['waze'], default=0)))
    print('  LEFT snapped (neither source places them): %d'
          % stats['unmatched'])
    print('  skipped (kind dropped at load anyway)   : %d'
          % stats['skipped_kind'])
    left = collections.Counter(
        s['kind'] for s in signs
        if s.get('lat') is not None and on_grid(s['lat']) and on_grid(s['lng']))
    print('     ', dict(left.most_common(8)))
    if not a.write:
        print('\nDRY RUN — nothing written. Re-run with --write.')
        return 0
    bak = ASSET.with_suffix(f'.json.bak_{time.strftime("%Y%m%d_%H%M%S")}')
    shutil.copy2(ASSET, bak)
    doc['generated'] = time.strftime('%Y-%m-%d (coords repaired)')
    with open(ASSET, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print('\nwrote %s (backup %s)' % (ASSET.name, bak.name))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
