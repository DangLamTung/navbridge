"""Do the turn signs sit where a turn exists?

A cấm rẽ trái / chỉ rẽ trái sign only makes sense at a junction. Using the
Waze segment layer as an independent map, each turn sign is checked against the
set of street names around it: at a real junction at least TWO different
streets are within ~30 m. Signs with only one street around them are listed.

    python3 tool/audit_turn_signs.py [--near LAT,LNG]
"""
import argparse
import json
import math
import sys
from collections import Counter

sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
import trip_truth as T  # noqa: E402
from app_rules import road_key  # noqa: E402
from waze_segments import CELL_DEG  # noqa: E402

REPO = '/Users/tungdl/Documents/Eink/navbridge'
KINDS = ('no_left_turn', 'no_right_turn', 'no_u_turn', 'only_left',
         'only_right', 'only_straight')

segs = T.Segments(REPO + '/assets/offline_map/waze_segments.bin')
signs = json.load(open(REPO + '/assets/offline_map/vietnam_signs.json'))['signs']


def streets_near(lat, lng, radius=30.0):
    gy, gx = int(math.floor(lat / CELL_DEG)), int(math.floor(lng / CELL_DEG))
    out = {}
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for s in segs.grid.get((gy + dy, gx + dx), ()):
                name = segs.street(s)
                if not name:
                    continue
                d, _, _ = segs._geom(lat, lng, segs.pts[s])
                if d <= radius:
                    k = road_key(name)
                    if k and (k not in out or d < out[k]):
                        out[k] = d
    return out


ap = argparse.ArgumentParser()
ap.add_argument('--near')
a = ap.parse_args()
near = None
if a.near:
    la, ln = (float(v) for v in a.near.split(','))
    near = (la, ln)

per = Counter()
suspicious = []
for s in signs:
    if s.get('kind') not in KINDS:
        continue
    lat, lng = s.get('lat'), s.get('lng')
    if lat is None:
        continue
    if near and math.hypot((lat - near[0]) * 111320,
                           (lng - near[1]) * 111320 * 0.985) > 1500:
        continue
    ns = streets_near(lat, lng)
    per[s['kind']] += 1
    if len(ns) < 2:
        suspicious.append((s['kind'], lat, lng, list(ns.keys()),
                           s.get('source')))

print('turn signs examined:', sum(per.values()), dict(per))
print('with only ONE street within 30 m (no junction): %d (%d%%)'
      % (len(suspicious),
         100 * len(suspicious) / max(1, sum(per.values()))))
by_kind = Counter(x[0] for x in suspicious)
for k, v in by_kind.most_common():
    print('   %-16s %4d of %4d' % (k, v, per[k]))
print()
for k, lat, lng, streets, src in suspicious[:12]:
    print('  %-16s %.5f,%.5f  streets=%s  source=%s'
          % (k, lat, lng, streets, src))
