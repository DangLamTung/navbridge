#!/usr/bin/env python3
"""Validate the POI-density city test against real drives and rural samples.

`lib/services/urban_area.dart` decides "is this a built-up area?" from POI
density (>= kUrbanPoiMin = 25 POIs within 2 km) instead of the removed
khu-đông-dân-cư boundary signs. This tool checks the separation on real data:

  * every fix of the recorded city drives (should be urban, ~100%)
  * hand-picked rural points on QL1 / QL20 / Tây Ninh (should be rural, 0)

Usage: python3 tool/urban_probe.py
"""
from __future__ import annotations

import glob
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POIS = os.path.join(REPO, 'assets/offline_map/vietnam_pois.json')
CELL = 0.01          # ~1.1 km at 10-20° N
RADIUS_CELLS = 2     # 5x5 window ~ 5.5 km wide, POIs counted within 2 km below
MIN_POIS = 25
RADIUS_M = 2000.0


def build_grid():
    with open(POIS, encoding='utf-8') as fh:
        doc = json.load(fh)
    pts = []
    for cat in doc.values():
        for it in cat.get('items', []) if isinstance(cat, dict) else []:
            if it.get('lat') is None or it.get('lng') is None:
                continue
            pts.append((float(it['lat']), float(it['lng'])))
    grid = {}
    for lat, lng in pts:
        k = ((int(lat / CELL)) << 16) | (int(lng / CELL) & 0xFFFF)
        grid[k] = grid.get(k, 0) + 1
    return pts, grid


def density(pts, lat, lng) -> int:
    n = 0
    for a, b in pts:
        if abs(a - lat) > RADIUS_M / 111000:
            continue
        if abs(b - lng) > RADIUS_M / 109000:
            continue
        dy = (a - lat) * 111000.0
        dx = (b - lng) * 109000.0
        if dy * dy + dx * dx <= RADIUS_M * RADIUS_M:
            n += 1
    return n


def main() -> int:
    pts, grid = build_grid()
    print(f'{len(pts)} bundled POIs, grid cells: {len(grid)}')

    def fast(lat, lng):
        cy, cx = int(lat / CELL), int(lng / CELL)
        n = 0
        for dy in range(-RADIUS_CELLS, RADIUS_CELLS + 1):
            for dx in range(-RADIUS_CELLS, RADIUS_CELLS + 1):
                n += grid.get(((cy + dy) << 16) | ((cx + dx) & 0xFFFF), 0)
        return n

    print('\n--- recorded city drives (expect urban) ---')
    trips = sorted(glob.glob(os.path.join(REPO, 'docs/trips/device/*.json')))
    for path in trips[:6]:
        with open(path, encoding='utf-8') as fh:
            locs = json.load(fh).get('locations') or []
        sample = [e for e in locs[::25] if e.get('latitudeE7')]
        if not sample:
            continue
        ds = [fast(e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7)
              for e in sample]
        urban = sum(1 for d in ds if d >= MIN_POIS)
        print(f'  {os.path.basename(path)[:30]:<32} {len(ds):>4} fix samples, '
              f'urban {100 * urban / len(ds):>3.0f}%, min density {min(ds)}')

    print('\n--- rural samples (expect rural) ---')
    rural = {
        'QL1 Phú Yên': (13.100, 109.200),
        'QL20 Đà Lạt pass': (11.900, 108.300),
        'Tây Ninh field': (11.400, 105.900),
        'Đắk Nông forest': (12.200, 107.600),
        'HCMC centre': (10.776, 106.700),
        'HCMC Quận 7': (10.730, 106.720),
        'Hà Nội Hoàn Kiếm': (21.028, 105.854),
        'Đà Nẵng Hải Châu': (16.060, 108.220),
    }
    for name, (lat, lng) in rural.items():
        exact = density(pts, lat, lng)
        print(f'  {name:<20} exact {exact:>4}  fast {fast(lat, lng):>4}  '
              f'-> {"URBAN" if exact >= MIN_POIS else "rural"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
