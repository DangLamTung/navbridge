"""Compare the Waze SEGMENT layer against OSM `maxspeed` on the same roads.

Independent sources: the layer is a Waze WME crawl, OSM maxspeed is
community-curated. Sampling the layer AT each tagged OSM way's own geometry
(with the way's direction as heading) is the strongest data check available
offline.

Usage: python3 tool/compare_waze_vs_osm.py [lat_min lat_max lng_min lng_max]
"""
import json
import math
import os
import sys
import urllib.parse
import urllib.request
from collections import Counter

sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
from waze_segments import M_PER_DEG_LAT, Segments  # noqa: E402

REPO = '/Users/tungdl/Documents/Eink/navbridge'
BBOX = tuple(float(x) for x in sys.argv[1:5]) if len(sys.argv) >= 5 \
    else (10.75, 10.83, 106.62, 106.72)          # central HCMC
CACHE = f'/tmp/osm_maxspeed_{BBOX[0]}_{BBOX[2]}.json'

if os.path.exists(CACHE):
    osm = json.load(open(CACHE))
else:
    q = (f'[out:json][timeout:180];way({BBOX[0]},{BBOX[2]},{BBOX[1]},{BBOX[3]})'
         '["highway"]["maxspeed"];out tags geom;')
    req = urllib.request.Request(
        'https://overpass-api.de/api/interpreter',
        data=urllib.parse.urlencode({'data': q}).encode(),
        headers={'User-Agent': 'navbridge-dev/1.0 (waze layer data check)'})
    with urllib.request.urlopen(req, timeout=300) as r:
        osm = json.load(r)
    json.dump(osm, open(CACHE, 'w'))

seg = Segments(os.path.join(REPO, 'assets/offline_map/waze_segments.bin'))
ways = [e for e in osm['elements']
        if (e.get('tags') or {}).get('maxspeed') and len(e.get('geometry') or []) >= 2]
print(f'OSM ways with maxspeed in bbox {BBOX}: {len(ways)}')


def tag_kmh(t):
    v = t.get('maxspeed')
    if not isinstance(v, str):
        return 0
    if 'mph' in v:
        return round(int(''.join(c for c in v if c.isdigit()) or 0) * 1.60934)
    d = ''.join(c for c in v if c.isdigit())
    return int(d) if d else 0


same = diff = miss = 0
same_road_diff = 0
other_road_diff = 0
pair = Counter()
pair = Counter()
rows = []
import sys as _sys
_sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
from app_rules import same_road  # noqa: E402
for w in ways:
    t = w['tags']
    osm_v = tag_kmh(t)
    if not (5 <= osm_v <= 200):
        continue
    g = w['geometry']
    pts = [(p['lat'], p['lon']) for p in g]
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        leg = math.hypot((b[0] - a[0]) * M_PER_DEG_LAT,
                         (b[1] - a[1]) * M_PER_DEG_LAT * math.cos(math.radians(a[0])))
        if leg > 400:            # sparse shape points: skip, not a road stretch
            continue
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        brg = (math.degrees(math.atan2((b[1] - a[1]) * math.cos(math.radians(a[0])),
                                       b[0] - a[0])) + 360.0) % 360.0
        kmh, street, _, _, dist, sid = seg.query(mid[0], mid[1],
                                                 heading_deg=brg)
        if sid is None or not kmh:
            miss += 1
            continue
        if kmh == osm_v:
            same += 1
        else:
            diff += 1
            # Same street, different value = a real data conflict between the
            # Waze crawl and OSM. Different street = the crossing/junction
            # match (a geometry choice, not a wrong posted value).
            if t.get('name') and street and same_road(t['name'], street):
                same_road_diff += 1
                pair[f'{osm_v} -> {kmh}'] += 1
            else:
                other_road_diff += 1
            if len(rows) < 40:
                rows.append((round(mid[0], 5), round(mid[1], 5), osm_v, kmh,
                             t.get('highway'), t.get('name'), street, dist,
                             t.get('maxspeed')))

print(f'\nroad stretches compared (midpoint of each OSM leg):')
print(f'  layer agreed with OSM maxspeed : {same}')
print(f'  layer DISAGREED                : {diff}')
print(f'  no segment within 25 m         : {miss}')
tot = same + diff
print(f'  agreement: {100*same/max(1, tot):.1f}% of {tot}')
print(f'  of the {diff} disagreements:')
print(f'    same street, different VALUE (a real data conflict): '
      f'{same_road_diff}')
print(f'    different street (junction/crossing match, not a value): '
      f'{other_road_diff}')
if pair:
    print('  the same-street conflicts, by (osm -> layer):')
    for k, v in pair.most_common(8):
        print(f'    {k:<12} {v:>5}')
if pair:
    print('  the same-street conflicts, by (osm -> layer):')
    for k, v in pair.most_common(8):
        print(f'    {k:<12} {v:>5}')
print('\nworst disagreements (layer vs OSM):')
for r in sorted(rows, key=lambda x: -abs(x[3] - x[2]))[:25]:
    print(f'  {r[0]},{r[1]} osm={r[2]} layer={r[3]} ({r[4]}, osm name '
          f'{r[5]!r}, layer name {r[6]!r}, {r[7]:.1f} m, tag {r[8]!r})')
