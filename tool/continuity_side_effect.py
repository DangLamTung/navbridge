"""What the continuity band costs, measured over every recorded drive.

The band (see `_pickWithContinuity` in lib/services/offline_speed_limits.dart)
holds the value on screen while a record carrying it sits within `band` metres
of the best candidate. Two effects, both counted here:

  - value changes suppressed: the flicker between parallel records of ONE road
    (Cộng Hòa 60 at 3.0 m / Cộng Hoà 50 at 5.5 m, 2026-09-22 20:48 drive);
  - holds across a STREET change: the car has turned and the road it left still
    has a record within the band, so the old value stays for a fix. The name
    hysteresis holds the NAME for the same reason, so the two stay consistent —
    but it is a lag and must be known, not hidden.

Run: python3 tool/continuity_side_effect.py
"""
import glob
import json
import math
import os
import sys

sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
import trip_truth as T  # noqa: E402
from app_rules import same_road  # noqa: E402
from waze_segments import CELL_DEG  # noqa: E402

segs = T.Segments('/Users/tungdl/Documents/Eink/navbridge/'
                  'assets/offline_map/waze_segments.bin')


def cands(lat, lng, hd, max_d=25.0):
    gy, gx = int(math.floor(lat / CELL_DEG)), int(math.floor(lng / CELL_DEG))
    out, seen = [], set()
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for s in segs.grid.get((gy + dy, gx + dx), ()):
                if s in seen:
                    continue
                seen.add(s)
                d, brg, over = segs._geom(lat, lng, segs.pts[s])
                if d <= max_d:
                    out.append((d, s, brg, over, segs.value(s, hd, brg),
                                segs.street(s)))
    return out


def pick(cs, keep_val, band):
    if not cs:
        return None, None
    best = min(cs, key=lambda c: c[0])
    if keep_val is not None:
        pool = [c for c in cs if c[4] == keep_val and c[0] <= best[0] + band]
        if pool:
            c = min(pool, key=lambda c: c[0])
            return c[4], c[5]
    return best[4], best[5]


for band in (2.0, 4.0, 6.0, 8.0):
    same = other = before = after = 0
    for path in sorted(glob.glob('/Users/tungdl/Documents/Eink/navbridge/'
                                 'docs/trips/device/2026-09-*.json')):
        prev_val = prev_name = None
        prev_kept = None
        for e in json.load(open(path))['locations']:
            if not e.get('latitudeE7'):
                continue
            lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
            hd = e.get('heading')
            if not isinstance(hd, (int, float)):
                hd = None
            cs = cands(lat, lng, hd)
            plain, p_name = pick(cs, None, 0)
            kept, _ = pick(cs, prev_val, band)
            if prev_val and plain and prev_val and plain != prev_val:
                before += 1
            if prev_kept and kept and prev_kept and kept != prev_kept:
                after += 1
            if prev_val and plain and kept and plain != kept:
                if prev_name and p_name and same_road(prev_name, p_name):
                    same += 1
                else:
                    other += 1
            prev_val, prev_name = plain, p_name
            prev_kept = kept
    print('band %3.1f m: value changes %4d -> %4d   |  held: same-street %3d '
          '(flicker), different-street %3d (corner lag)'
          % (band, before, after, same, other))

import glob
import json
import os
import sys

sys.path.insert(0, '/Users/tungdl/Documents/Eink/navbridge/tool')
import trip_truth as T  # noqa: E402
from app_rules import same_road  # noqa: E402

segs = T.Segments('/Users/tungdl/Documents/Eink/navbridge/'
                  'assets/offline_map/waze_segments.bin')
