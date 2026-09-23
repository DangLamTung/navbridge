#!/usr/bin/env python3
"""Audit the Waze SEGMENT layer: container, data, and reader correctness.

Three questions, in order:

  1. CONTAINER — is the WZSG blob structurally sound (offsets, stream length,
     street table, coordinate bounds, point counts)?
  2. DATA — are the per-segment limits plausible, and do they agree with the
     INDEPENDENT Waze point layer and with OSM `maxspeed`?
  3. READER — does tool/waze_segments.py derive the same limit the app does?
     The app picks the direction from the bearing of the NEAREST SUB-SEGMENT in
     stored node order (offline_speed_limits.dart `_querySegIndex` uses
     `cands[win].$3`, i.e. `_bearingDeg(a -> b)`); anything else is a tool bug
     that silently inverts every per-direction (fwd != rev) segment.

Usage:
    python3 tool/audit_waze_segments.py [--fixes-per-trip N] [--fixture FILE]
"""

from __future__ import annotations

import glob
import json
import math
import os
import struct
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from waze_segments import CELL_DEG, M_PER_DEG_LAT, Segments  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')
POINTS = os.path.join(REPO, 'assets/offline_map/waze_speed_limits.json')
TRIPS = os.path.join(REPO, 'docs/trips/device')
OSM_CACHE = '/tmp/osm_ways_bbox.json'
VN = (8.0, 23.6, 102.0, 110.5)          # latMin, latMax, lngMin, lngMax

argv = sys.argv[1:]
fixture_path = argv[argv.index('--fixture') + 1] if '--fixture' in argv else None
per_trip = 40

fail = []


def check(ok: bool, label: str, detail: str = '') -> None:
    print(f'  {"OK  " if ok else "FAIL"} {label}{(" — " + detail) if detail else ""}')
    if not ok:
        fail.append(label)


# ---------------------------------------------------------------------------
# 1. container
# ---------------------------------------------------------------------------
with open(BIN, 'rb') as fh:
    raw = fh.read()
(magic, ver, n_pts, n_coord_b, n_segs, cell_e4, n_streets, lat0, lng0,
 name_b) = struct.unpack_from('<4sIIIIIIiiI', raw, 0)
print(f'\n== container ==  {os.path.basename(BIN)}  {len(raw)/1e6:.1f} MB')
print(f'  magic={magic} v{ver} nPoints={n_pts} nCoordB={n_coord_b} '
      f'nSegs={n_segs} cell={cell_e4}e-4 nStreets={n_streets} '
      f'lat0={lat0/1e5} lng0={lng0/1e5} names={name_b}B')
check(magic == b'WZSG', 'magic')
check(ver in (2, 3), 'version supported', str(ver))
check(cell_e4 == 50, 'cell is 0.005 deg (matches _segCellDeg)', f'{cell_e4}e-4')

hdr = 40 if ver >= 3 else 36
offsets = struct.unpack_from(f'<{n_segs + 1}I', raw, hdr)
check(offsets[0] == 0, 'offsets[0] == 0', str(offsets[0]))
mono = all(offsets[i] <= offsets[i + 1] for i in range(n_segs))
check(mono, 'offsets monotonic')
check(offsets[n_segs] == n_coord_b, 'coord stream length matches nCoordB',
      f'{offsets[n_segs]} vs {n_coord_b}')

base = hdr + (n_segs + 1) * 4
expect_end = base + n_coord_b + 2 * n_segs
if ver >= 3:
    expect_end += n_segs * 4 + n_segs + (n_streets + 1) * 4 + name_b
check(expect_end == len(raw), 'blob size matches the header', 
      f'{expect_end} vs {len(raw)}')

# ---------------------------------------------------------------------------
# 2. per-segment decode, geometry, classes
# ---------------------------------------------------------------------------
seg = Segments(BIN)
npts = [len(p) for p in seg.pts]
lim = Counter()
zero_zero = 0
heading_sensitive = 0
for s in range(n_segs):
    f, r = seg.fwd[s], seg.rev[s]
    lim[f] += 1
    lim[r] += 1
    if f == 0 and r == 0:
        zero_zero += 1
    if f and r and f != r:
        heading_sensitive += 1
print('\n== data ==')
print(f'  points/segment: min {min(npts)} median '
      f'{sorted(npts)[len(npts)//2]} max {max(npts)}')
check(min(npts) >= 2, 'every segment has >= 2 points',
      f'{sum(1 for n in npts if n < 2)} below')
over_cap = sum(1 for n in npts if n > 511)
check(over_cap == 0, 'no segment exceeds the Dart 511-point decode cap',
      f'{over_cap} over' if over_cap else '')
print(f'  limits (fwd+rev histogram): '
      f'{dict(sorted((k, v) for k, v in lim.items() if k) )}')
check(zero_zero == 0, 'no segment has 0/0 (a no-limit winner would still set '
      'lastWazeStreetName in the app)',
      f'{zero_zero} of {n_segs}' if zero_zero else '0 of %d' % n_segs)
print(f'  per-direction (fwd != rev, both set): {heading_sensitive} '
      f'({100*heading_sensitive/n_segs:.2f}%)')

bad_range = sum(1 for v in lim
                if v and (v < 5 or v > 200))
check(bad_range == 0, 'every posted value is 5..200 km/h', f'{bad_range} values')
weird = [v for v in lim if v and (v < 10 or v > 130)]
print(f'  unusual values outside 10..130: {sorted(weird) or "none"}')

named = sum(1 for n in seg.streets if n)
print(f'  named segments: {named} ({100*named/n_segs:.1f}%) of {n_segs}')
idx_bad = 0
if ver >= 3:
    seg_street_off = base + n_coord_b + 2 * n_segs
    idxs = struct.unpack_from(f'<{n_segs}I', raw, seg_street_off)
    idx_bad = sum(1 for i in idxs if i != 0xFFFFFFFF and i >= n_streets)
check(idx_bad == 0, 'every street index is in range', f'{idx_bad} bad')

cls = Counter(seg.classes[i] & 0x3F for i in range(n_segs))
sep = sum(1 for i in range(n_segs) if seg.classes[i] & 0x80)
print(f'  roadType histogram: {dict(sorted(cls.items()))}')
print(f'  separator bit set: {sep} of {n_segs}'
      f'{"  (documented as carrying no signal)" if sep == 0 else ""}')

# geometry sanity
outside = 0
far = 0
span_skipped = 0
cn = seg.classes
for s in range(n_segs):
    pts = seg.pts[s]
    for (la, ln) in pts:
        if not (VN[0] <= la <= VN[1] and VN[2] <= ln <= VN[3]):
            outside += 1
            break
    if len(pts) >= 2:
        run = 0.0
        for i in range(len(pts) - 1):
            run += math.hypot((pts[i + 1][0] - pts[i][0]) * M_PER_DEG_LAT,
                              (pts[i + 1][1] - pts[i][1]) * M_PER_DEG_LAT *
                              math.cos(math.radians(pts[i][0])))
        if run > 1000.0:
            far += 1
        # the app's grid skips a segment whose bbox spans > 256 cells of 0.005
        e5 = 500
        xs = [int(p[1] * 1e5) // e5 for p in pts]
        ys = [int(p[0] * 1e5) // e5 for p in pts]
        if (max(xs) - min(xs) + 1) * (max(ys) - min(ys) + 1) > 256:
            span_skipped += 1
check(outside == 0, 'every coordinate is inside the VN bbox',
      f'{outside} segments outside')
print(f'  segments longer than 1 km: {far}')
print(f'  skipped by the app grid (bbox > 256 cells), mirrored by the reader: '
      f'{seg.grid_skipped}  (all sea/ferry or inter-city jumps)')
check(seg.grid_skipped == span_skipped,
      'reader grid rule matches the app',
      f'{seg.grid_skipped} vs {span_skipped}')

# grid coverage parity: the tool indexes a segment in every cell its bbox
# touches; the app does the same except for the >256-cell case above. Compare
# cell counts on a sample so a silent index mismatch cannot hide.
sample_cells = list(seg.grid.items())[:2000]
tool_n = sum(len(v) for _, v in sample_cells)
print(f'  grid: {len(seg.grid)} cells; first 2000 cells hold {tool_n} refs')

# ---------------------------------------------------------------------------
# 3. reader parity: the app's direction rule vs tool value()
# ---------------------------------------------------------------------------
def app_value(s: int, lat: float, lng: float, heading):
    """speedLimitAt()'s value with its own bearing: the NEAREST sub-segment,
    measured in stored node order."""
    f, r = seg.fwd[s], seg.rev[s]
    if f == 0 and r == 0:
        return 0
    if f == r or f == 0:
        return r
    if r == 0:
        return f
    if heading is None:
        return max(f, r)
    _, brg, _ = seg._geom(lat, lng, seg.pts[s])
    delta = abs(heading - brg) % 360.0
    if delta > 180:
        delta = 360 - delta
    return f if delta <= 90 else r
trips = sorted(glob.glob(os.path.join(TRIPS, '*.json')))[-6:]
diff = tot = 0
examples = []
fixture = []
for tp in trips:
    d = json.load(open(tp))
    fixes = [f for f in d.get('locations', []) if f.get('latitudeE7')]
    step = max(1, len(fixes) // per_trip)
    for f in fixes[::step][:per_trip]:
        lat = f['latitudeE7'] / 1e7
        lng = f['longitudeE7'] / 1e7
        heading = f.get('heading')
        if not heading:
            heading = None
        kmh, street, cls_v, sep_v, dist, sid = seg.query(
            lat, lng, heading_deg=heading)
        if sid is None:
            continue
        tot += 1
        want = app_value(sid, lat, lng, heading)
        got = kmh
        if want != got:
            diff += 1
            if len(examples) < 6:
                f_, r_ = seg.fwd[sid], seg.rev[sid]
                examples.append(
                    (os.path.basename(tp)[:16], round(lat, 5), round(lng, 5),
                     heading, f_, r_, got, want, street))
        if fixture_path and len(fixture) < 300:
            fixture.append({'lat': round(lat, 6), 'lng': round(lng, 6),
                            'heading': heading, 'kmh': want,
                            'street': seg.street(sid), 'layer': 'segment',
                            'dist': round(dist, 2)})

print('\n== reader parity (tool query() vs the app reimplemented from Dart) ==')
print(f'  sampled fixes with a segment hit: {tot}')
print(f'  per-direction value differs:      {diff} '
      f'({100*diff/max(1, tot):.1f}%)')
for e in examples:
    print(f'    {e[0]} {e[1]},{e[2]} hdg={e[3]} fwd={e[4]} rev={e[5]} '
          f'tool={e[6]} app={e[7]} {e[8]!r}')


def app_query(lat, lng, heading, max_dist_m=25.0):
    """The app's `_querySegIndex` + `pickSegmentCandidate` + `segmentScore`,
    reimplemented here straight from offline_speed_limits.dart so the check does
    not lean on the code it is checking."""
    cx = int(math.floor(lng / CELL_DEG))
    cy = int(math.floor(lat / CELL_DEG))
    cands = []                                    # (s, d, brg, over)
    for dx in (-1, 0, 1):                         # x outer, y inner (as Dart)
        for dy in (-1, 0, 1):
            for s in seg.grid.get((cy + dy, cx + dx), ()):
                d, brg, over = seg._geom(lat, lng, seg.pts[s])
                cands.append((s, d, brg, over))
    best_i, best_score = -1, float('inf')
    for i, (_s, d, brg, over) in enumerate(cands):
        if d > max_dist_m:                        # hard range gate first
            continue
        score = d
        if heading is not None:
            delta = abs(heading - brg) % 180.0
            if delta > 90:
                delta = 180 - delta
            if delta > 45.0:
                score += max_dist_m + 1
        if over > 10.0:
            score += max_dist_m + 1
        if score < best_score:
            best_score, best_i = score, i
    if best_i < 0:
        return None, None
    s, _d, brg, _o = cands[best_i]
    f, r = seg.fwd[s], seg.rev[s]
    if f == 0 and r == 0:
        return None, s
    if f == r or f == 0:
        return r, s
    if r == 0:
        return f, s
    if heading is None:
        return (f if f > r else r), s
    delta = abs(heading - brg) % 360.0
    if delta > 180:
        delta = 360 - delta
    return (f if delta <= 90 else r), s


# (b) full parity over real fixes AND over points taken from segment geometry
probe_pts = []
for tp in trips:
    d = json.load(open(tp))
    fixes = [f for f in d.get('locations', []) if f.get('latitudeE7')]
    step = max(1, len(fixes) // per_trip)
    for f in fixes[::step][:per_trip]:
        probe_pts.append((f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7,
                          f.get('heading') or None))
for s in range(0, n_segs, n_segs // 900):
    pts = seg.pts[s]
    if len(pts) >= 2:
        mid = pts[len(pts) // 2]
        probe_pts.append((mid[0], mid[1], None))
        probe_pts.append((mid[0], mid[1], seg._bearing(s)))
mismatch = 0
expected_none = 0
for (lat, lng, hdg) in probe_pts:
    got = seg.query(lat, lng, heading_deg=hdg)
    want, sid = app_query(lat, lng, hdg)
    got_v = got[0] if got[5] is not None else None
    if got_v == 0:
        got_v = None
    if got_v != want or (got[5] is not None) != (sid is not None):
        mismatch += 1
        if mismatch <= 5:
            print(f'    MISMATCH {lat:.5f},{lng:.5f} hdg={hdg} '
                  f'tool={got_v}/seg {got[5]} app={want}/seg {sid}')
    if want is None:
        expected_none += 1
print(f'  probe points: {len(probe_pts)} ({expected_none} with no app answer)')
check(mismatch == 0, 'query() reproduces the app on every probe',
      f'{mismatch} mismatches')

# (a) deterministic direction contract on the per-direction segments
sens = [s for s in range(n_segs) if seg.fwd[s] and seg.rev[s]
        and seg.fwd[s] != seg.rev[s]]
bad_dir = 0
probed = 0
ex_dir = []
for s in sens[::max(1, len(sens) // 4000)]:
    pts = seg.pts[s]
    if len(pts) < 2:
        continue
    mid = pts[len(pts) // 2]
    brg = seg._geom(mid[0], mid[1], pts)[1]
    for hdg, want in ((brg, seg.fwd[s]), ((brg + 180) % 360, seg.rev[s])):
        probed += 1
        got = seg.value(s, hdg, brg)
        if got != want:
            bad_dir += 1
            if len(ex_dir) < 4:
                ex_dir.append((s, round(hdg, 1), round(brg, 1), seg.fwd[s],
                               seg.rev[s], got, want, seg.street(s)))
print(f'  per-direction segments: {len(sens)};  direction contract probed '
      f'{probed}')
print(f'  value() inverted the direction on: {bad_dir} '
      f'({100*bad_dir/max(1, probed):.0f}%)')
for e in ex_dir:
    print(f'    seg {e[0]} hdg={e[1]} brg={e[2]} fwd={e[3]} rev={e[4]} '
          f'got={e[5]} want={e[6]} {e[7]!r}')
check(bad_dir == 0, 'value() honours the app\'s fwd/rev rule',
      f'{bad_dir} inverted of {probed}')
for e in ex_dir:
    print(f'    seg {e[0]} hdg={e[1]} storedBrg={e[2]} fwd={e[3]} rev={e[4]} '
          f'tool={e[5]} app={e[6]} {e[7]!r}')

# ---------------------------------------------------------------------------
# 3b. geometry risk: a leg between two consecutive points that jumps far
# ---------------------------------------------------------------------------
jump_legs = 0
city_jump = 0
worst = []
for s in range(n_segs):
    pts = seg.pts[s]
    for i in range(len(pts) - 1):
        leg = math.hypot((pts[i + 1][0] - pts[i][0]) * M_PER_DEG_LAT,
                         (pts[i + 1][1] - pts[i][1]) * M_PER_DEG_LAT *
                         math.cos(math.radians(pts[i][0])))
        if leg > 1000.0:
            jump_legs += 1
            la, ln = pts[i][0], pts[i][1]
            in_city = 10.6 <= la <= 11.1 and 106.4 <= ln <= 107.0
            if in_city:
                city_jump += 1
            if len(worst) < 6 or leg > worst[-1][0]:
                worst.append((leg, s, la, ln, seg.fwd[s], seg.rev[s],
                              seg.street(s)))
                worst.sort(reverse=True)
                worst = worst[:6]
print('\n== geometry ==')
print(f'  consecutive-point legs > 1 km: {jump_legs};  starting inside HCMC: '
      f'{city_jump}')
for w in worst[:4]:
    print(f'    {w[0]/1000:.1f} km leg in seg {w[1]} at {w[2]:.4f},{w[3]:.4f} '
          f'({w[4]}/{w[5]} km/h, {w[6]!r})')

# ---------------------------------------------------------------------------
# 3c. how often would the chip show a value that cannot be a VN posted sign?
standard = {20, 30, 40, 50, 60, 70, 80, 90, 100, 120}
off_the_fixes = Counter()
for tp in trips:
    d = json.load(open(tp))
    fixes = [f for f in d.get('locations', []) if f.get('latitudeE7')]
    for f in fixes:
        lat = f['latitudeE7'] / 1e7
        lng = f['longitudeE7'] / 1e7
        kmh, _, _, _, _, sid = seg.query(lat, lng)
        if sid is not None and kmh and kmh not in standard:
            off_the_fixes[kmh] += 1
print('\n== values that are not a plausible VN posted sign (at real fixes) ==')
print(f'  {sum(off_the_fixes.values())} fixes -> '
      f'{dict(off_the_fixes.most_common(8))}')

# ---------------------------------------------------------------------------
# 4. independent sources
# ---------------------------------------------------------------------------
pts_layer = json.load(open(POINTS))['points']
pcell = {}
PDEG = 0.02
for i, p in enumerate(pts_layer):
    k = (int(math.floor(p['lng'] / PDEG)), int(math.floor(p['lat'] / PDEG)))
    pcell.setdefault(k, []).append(i)
agree = dis = 0
disp = []
for tp in trips:
    d = json.load(open(tp))
    fixes = [f for f in d.get('locations', []) if f.get('latitudeE7')]
    step = max(1, len(fixes) // per_trip)
    for f in fixes[::step][:per_trip]:
        lat = f['latitudeE7'] / 1e7
        lng = f['longitudeE7'] / 1e7
        kmh, _, _, _, dist, sid = seg.query(lat, lng)
        if sid is None:
            continue
        cx, cy = int(math.floor(lng / PDEG)), int(math.floor(lat / PDEG))
        best, bkmh = 1e9, None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in pcell.get((cx + dx, cy + dy), ()):
                    p = pts_layer[i]
                    dd = math.hypot((p['lat'] - lat) * M_PER_DEG_LAT,
                                    (p['lng'] - lng) * M_PER_DEG_LAT *
                                    math.cos(math.radians(lat)))
                    if dd < best:
                        best, bkmh = dd, p['kmh']
        if bkmh is None or best > 25.0:
            continue
        if bkmh == kmh:
            agree += 1
        else:
            dis += 1
            if len(disp) < 6:
                disp.append((round(lat, 5), round(lng, 5), kmh, bkmh,
                             round(best, 1), dist))
print('\n== Waze point layer (independent crawl of the same signs) ==')
print(f'  fixes where both layers have data within 25 m: {agree + dis}')
print(f'  same value: {agree}; different: {dis}')
for e in disp:
    print(f'    {e[0]},{e[1]} segment={e[2]} point={e[3]} '
          f'(point {e[4]} m away, segment {e[5]:.1f} m)')

# OSM maxspeed on the ways near the trip's own fixes (cached Overpass bbox)
if os.path.exists(OSM_CACHE):
    osm = json.load(open(OSM_CACHE))
    ways = []
    for e in osm.get('elements', []):
        t = e.get('tags', {})
        g = e.get('geometry') or []
        if len(g) >= 2 and t.get('highway'):
            ways.append((t, g))
    same = other = 0
    oexamples = []
    for tp in trips[:2]:
        d = json.load(open(tp))
        fixes = [f for f in d.get('locations', []) if f.get('latitudeE7')]
        step = max(1, len(fixes) // per_trip)
        for f in fixes[::step][:per_trip]:
            lat = f['latitudeE7'] / 1e7
            lng = f['longitudeE7'] / 1e7
            kmh, street, _, _, _, sid = seg.query(lat, lng)
            if sid is None:
                continue
            best, tag = 1e9, None
            for t, g in ways:
                ms = t.get('maxspeed')
                if not ms:
                    continue
                for i in range(len(g) - 1):
                    a, b = g[i], g[i + 1]
                    ax, ay = a['lon'], a['lat']
                    bx, by = b['lon'], b['lat']
                    dx, dy = bx - ax, by - ay
                    l2 = dx * dx + dy * dy
                    if l2 <= 1e-12:
                        continue
                    tt = max(0.0, min(1.0, ((lng - ax) * dx + (lat - ay) * dy)
                                     / l2))
                    dd = math.hypot((lng - (ax + tt * dx)) * M_PER_DEG_LAT *
                                    math.cos(math.radians(lat)),
                                    (lat - (ay + tt * dy)) * M_PER_DEG_LAT)
                    if dd < best:
                        best, tag = dd, ms
            if tag is None or best > 20.0:
                continue
            try:
                v = int(''.join(ch for ch in str(tag) if ch.isdigit()) or 0)
            except ValueError:
                v = 0
            if not v:
                continue
            if v == kmh:
                same += 1
            else:
                other += 1
                if len(oexamples) < 6:
                    oexamples.append((round(lat, 5), round(lng, 5), kmh, v,
                                      str(tag), round(best, 1), street))
    print('\n== OSM maxspeed (independent, curated) near the same fixes ==')
    print(f'  both sources give a value: {same + other};  same: {same}; '
          f'different: {other}')
    for e in oexamples:
        print(f'    {e[0]},{e[1]} segment={e[2]} osm={e[3]} (tag {e[4]!r}, '
              f'{e[5]} m, {e[6]!r})')
else:
    print('\n== OSM maxspeed == (no /tmp/osm_ways_bbox.json cache)')

# ---------------------------------------------------------------------------
if fixture_path:
    json.dump(fixture, open(fixture_path, 'w'), ensure_ascii=False, indent=1)
    print(f'\nwrote {len(fixture)} parity samples -> {fixture_path}')

print('\n== verdict ==')
print('  all structural/data checks passed' if not fail
      else '  FAILURES: ' + '; '.join(fail))
if diff:
    print(f'  READER BUG: tool/waze_segments.py disagrees with the app on '
          f'{diff}/{tot} sampled per-direction hits')
