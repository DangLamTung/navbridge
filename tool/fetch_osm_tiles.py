#!/usr/bin/env python3
"""Fetch a small OSM raster tile bundle for Việt Nam (national view) so the
coverage map still shows a street basemap when opened OFFLINE (e.g. in a
sandboxed preview). Light usage (≈90 tiles, one-off) — respects OSM policy.

  :param; Writes: docs/waze_tiles/{z}/{x}/{y}.png  (Z5..Z8 over the VN bbox)
The viewer (overlay_waze_coverage.py) loads these first, then falls back to
https://basemaps.cartocdn.com/light_all/... for deeper zooms when online.
(OSM's own tile.openstreetmap.org is unreachable from sandboxed envs; Carto
light is keyless + same style the app uses.)
"""
import math
import os
import time
import urllib.request

ROOT = os.path.join(os.path.dirname(__file__), '..')
OUT = os.path.join(ROOT, 'docs', 'waze_tiles')

# Việt Nam bounding box
LON0, LON1 = 102.0, 110.0
LAT0, LAT1 = 8.5, 23.5

MINZ, MAXZ = 5, 8
UA = 'NavBridge-coverage-tool/1.0 (offline tile bundle)'


def deg_to_tile(lat, lon, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    latr = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(latr)) / math.pi) / 2.0 * n)
    return x, y


def fetch(url, path):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    return len(data)


def main():
    total, skipped = 0, 0
    for z in range(MINZ, MAXZ + 1):
        x0, y0 = deg_to_tile(LAT1, LON0, z)
        x1, y1 = deg_to_tile(LAT0, LON1, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                path = os.path.join(OUT, str(z), str(x), str(y) + '.png')
                if os.path.exists(path):
                    skipped += 1
                    continue
                url = f'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png'
                try:
                    n = fetch(url, path)
                    total += 1
                    print(f'  z{z} {x},{y} {n//1024}KB')
                except Exception as e:
                    print(f'  FAIL z{z} {x},{y}: {e}')
                time.sleep(0.15)
    print(f'done: downloaded={total} skipped(existing)={skipped}')


if __name__ == '__main__':
    main()
