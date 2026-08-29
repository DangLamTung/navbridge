#!/usr/bin/env python3
"""Analyze the geographic coverage/sparseness of vietnam_speed_limits.geojson."""
import collections
import json
import os
import sys

SRC = os.path.join(
    os.path.dirname(__file__), '..', 'assets', 'offline_map',
    'vietnam_speed_limits.geojson',
)


def main():
    with open(SRC) as f:
        data = json.load(f)
    feats = data['features']
    print('features:', len(feats))

    min_lon = min_lat = float('inf')
    max_lon = max_lat = float('-inf')
    cells = collections.Counter()      # 0.5-deg occupancy
    seg_pts = 0
    for ft in feats:
        g = ft['geometry']
        coords = g['coordinates']
        parts = coords if g['type'] == 'MultiLineString' else [coords]
        for part in parts:
            for c in part:
                lon, lat = c[0], c[1]
                min_lon = min(min_lon, lon); max_lon = max(max_lon, lon)
                min_lat = min(min_lat, lat); max_lat = max(max_lat, lat)
                cells[(round(lon * 2) / 2, round(lat * 2) / 2)] += 1
            seg_pts += len(part)

    print('lon range: %.3f .. %.3f  (%.2f deg)' % (min_lon, max_lon, max_lon - min_lon))
    print('lat range: %.3f .. %.3f  (%.2f deg)' % (min_lat, max_lat, max_lat - min_lat))
    print('total polyline points:', seg_pts)
    print('0.5-deg cells with data:', len(cells))

    # Vietnam approx land box (rough): lon 102..110, lat 8..23.5
    vn_cells = sum(
        1 for (lon, lat) in cells
        if 102 <= lon <= 110 and 8 <= lat <= 23.5
    )
    total_cells_0_5 = ((110 - 102) / 0.5) * ((23.5 - 8) / 0.5)
    print('VN 0.5-deg cells with data: %d / ~%d (%.0f%%)'
          % (vn_cells, total_cells_0_5, 100 * vn_cells / total_cells_0_5))

    # Points outside Vietnam bbox (anomalies / neighbors)
    outside = sum(
        1 for (lon, lat) in cells if not (102 <= lon <= 110 and 8 <= lat <= 23.5)
    )
    print('cells outside VN bbox:', outside)
    if outside:
        print('  samples:', [c for c in cells if not (102 <= c[0] <= 110 and 8 <= c[1] <= 23.5)][:20])

    # Top 15 densest cells
    top = cells.most_common(15)
    print('\nTop 15 densest 0.5-deg cells (lon,lat -> points):')
    for (lon, lat), n in top:
        print('  (%.1f, %.1f) : %d' % (lon, lat, n))

    # Roughly: how many segments have fwd==rev (symmetric) vs directional
    diff = sum(1 for ft in feats
               if ft['properties'].get('fwdMaxSpeed') != ft['properties'].get('revMaxSpeed'))
    print('\nsegments with fwd != rev:', diff)


if __name__ == '__main__':
    sys.exit(main())
