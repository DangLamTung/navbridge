#!/usr/bin/env python3
"""Replay a recorded trip through the CURRENT road rules, offline.

Answers "did the road-matching fix work?" without waiting for a drive. Per fix it
simulates what the app now does:

  1. the Waze segment pick — on-segment (interior) + aligned with the heading
     (mirrors pickSegmentCandidate in offline_speed_limits.dart);
  2. the road match — OSM ways scored by distance + heading alignment +
     overshoot, at the RAW fix position (the snapped-point lookup is gone);
  3. the route veto — the route's own street names for where the car is,
     reconstructed from the drive's own callouts
     ("Đi trên X, sau N mét, rẽ … vào Y");
  4. name hysteresis — 2 proposals or 30 m before a new name is published.

and compares the result with what the app actually logged, plus the limit the
corrected road would display (motorbike table + built-up rule) against the Waze
segment value under the car.

Baseline, 2026-09-21 17:33 drive (557 fixes):
    app street != nearest OSM way : 220 (39%)  ->  new rules: 14 (3%)
    218 street names corrected, 127 displayed limits changed
    (110 of them 60 -> 50 — over-claims removed)
    70 of the new limits equal the Waze segment value under the car.

Usage: python3 tool/replay_road_rules.py [<trip.json>]
"""

import datetime
import json
import math
import os
import re
import urllib.parse
import urllib.request

import sys
sys.path.insert(0, 'tool')
from waze_segments import (CELL_DEG, Segments, segment_line_angle,  # noqa: E402
                           segment_score)

TRIP = 'docs/trips/device/2026-09-21_173329_Chuyến_đi.json'
CACHE = '/tmp/osm_bbox_cache.json'
M = 111320.0
MAX_D = 25.0
MAX_OVER = 10.0
MAX_ANGLE = 45.0

d = json.load(open(TRIP))
fixes = sorted(d['locations'], key=lambda f: int(f['timestampMs']))
hh = lambda ms: datetime.datetime.fromtimestamp(int(ms) / 1000).strftime('%H:%M:%S')

# ---- route names, reconstructed from the drive's own callouts ----------------
INTO_RX = re.compile(r'vào ([^.,]+)')


def story(t):
    m = re.match(r'^Đi trên (.+?), sau .*', t)
    n = INTO_RX.search(t)
    return (m.group(1) if m else None, n.group(1) if n else None)


route_names = []  # (ms, {names})
for a in sorted(d['announcements'], key=lambda a: int(a['timestampMs'])):
    if a.get('kind') != 'maneuver':
        continue
    cur, nxt = story(a.get('text') or '')
    names = {x for x in (cur, nxt) if x}
    if names:
        route_names.append((int(a['timestampMs']), names))


def route_at(ms):
    best = set()
    for t, names in route_names:
        if t <= ms:
            best = names
        else:
            break
    return best


# ---- OSM ways for the trip bbox (cached) ------------------------------------
la = [((f.get('latitudeE7') or 0) / 1e7) for f in fixes if f.get('latitudeE7')]
ln = [((f.get('longitudeE7') or 0) / 1e7) for f in fixes if f.get('longitudeE7')]
bbox = (min(la) - 0.004, min(ln) - 0.004, max(la) + 0.004, max(ln) + 0.004)
if os.path.exists(CACHE):
    osm = json.load(open(CACHE))
else:
    q = (f'[out:json][timeout:120];way({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]})'
         '["highway"];out tags geom;')
    req = urllib.request.Request(
        'https://overpass-api.de/api/interpreter',
        data=urllib.parse.urlencode({'data': q}).encode(),
        headers={'User-Agent': 'navbridge-dev/1.0 (trip replay)'},
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        osm = json.load(r)
    json.dump(osm, open(CACHE, 'w'))

WAYS = []
for e in osm['elements']:
    g = e.get('geometry') or []
    if len(g) < 2:
        continue
    t = e.get('tags', {})
    WAYS.append((t.get('name'), t.get('highway'), g, t.get('oneway'),
                 t.get('lanes'), t.get('maxspeed')))


# The app's motorbike class table + built-up rule (lib/services/overpass.dart),
# so the replay can say what the corrected road would put on the chip.
MB = {
    'motorway': 80, 'motorway_link': 60, 'trunk': 60, 'trunk_link': 50,
    'primary': 60, 'primary_link': 50, 'secondary': 60, 'secondary_link': 50,
    'tertiary': 60, 'tertiary_link': 50, 'unclassified': 50, 'residential': 50,
    'living_street': 20, 'service': 30, 'pedestrian': 10, 'footway': 10,
    'cycleway': 20,
}
NON_MOTOR = ('motorway', 'motorway_link', 'living_street', 'service',
             'pedestrian', 'footway', 'cycleway')


def sim_limit(highway, oneway, lanes, posted):
    """What the app would show for this road (posted layer always wins)."""
    base = MB.get(highway or '', 50)
    if highway in NON_MOTOR:
        stat = base
    else:
        is_div = (str(oneway).lower() in ('yes', 'true', '1', '-1', 'reverse')) \
            and ((int(lanes) if str(lanes).isdigit() else 2) >= 2)
        stat = 60 if is_div else 50  # built-up rule (urban assumed, HCMC)
    if posted:
        return min(stat, int(posted)) if str(posted).isdigit() else stat
    return stat


def way_geom(lat, lng, geom):
    """(distance, bearing, overshoot) of the point against a way geometry."""
    ml = M * math.cos(math.radians(lat))
    px, py = lng * ml, lat * M
    best, bearing, over = float('inf'), 0.0, 0.0
    for i in range(len(geom) - 1):
        ax, ay = geom[i]['lon'] * ml, geom[i]['lat'] * M
        bx, by = geom[i + 1]['lon'] * ml, geom[i + 1]['lat'] * M
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        if l2 <= 1e-9:
            continue
        t_raw = ((px - ax) * dx + (py - ay) * dy) / l2
        t = max(0.0, min(1.0, t_raw))
        dd = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
        if dd < best:
            best = dd
            bearing = (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0
            ln_ = math.sqrt(l2)
            over = (-t_raw * ln_) if t_raw < 0 else (
                (t_raw - 1.0) * ln_ if t_raw > 1.0 else 0.0)
    return best, bearing, over


CELL = 0.002
grid = {}
for w in WAYS:
    for p in w[2]:
        grid.setdefault((int(p['lat'] // CELL), int(p['lon'] // CELL)), []).append(w)


def match_road(lat, lng, heading):
    """The new rule: score by distance + heading + overshoot, at the raw fix."""
    gy, gx = int(lat // CELL), int(lng // CELL)
    best, best_score, best_d = None, float('inf'), None
    for dy in range(-1, 2):
        for dx in range(-1, 2):
            for w in grid.get((gy + dy, gx + dx), ()):
                dd, brg, over = way_geom(lat, lng, w[2])
                if dd > MAX_D:
                    continue
                score = dd
                if heading and segment_line_angle(heading, brg) > MAX_ANGLE:
                    score += MAX_D + 1
                if over > MAX_OVER:
                    score += MAX_D + 1
                if score < best_score:
                    best_score, best, best_d = score, w, dd
    return best, best_d


# ---- replay -----------------------------------------------------------------
seg = Segments('assets/offline_map/waze_segments.bin')

import unicodedata  # noqa: E402


def key(s):
    s = unicodedata.normalize('NFD', (s or '').lower())
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return re.sub(r'[^a-z0-9]', '', s)


def same(a, b):
    ka, kb = key(a), key(b)
    return bool(ka and kb) and (ka == kb or ka in kb or kb in ka)


stats = {'fixes': 0, 'before_bad': 0, 'after_bad': 0, 'changed': 0}
changed_examples, still_bad = [], []
pending, count, moved_acc = None, 0, 0.0
published = None
prev_pos = None

for f in fixes:
    lat = (f.get('latitudeE7') or 0) / 1e7
    lng = (f.get('longitudeE7') or 0) / 1e7
    if not lat:
        continue
    ms = int(f['timestampMs'])
    heading = f.get('heading')
    moved = 0.0
    if prev_pos:
        moved = math.hypot((lat - prev_pos[0]) * M,
                           (lng - prev_pos[1]) * M * math.cos(math.radians(lat)))
    prev_pos = (lat, lng)
    stats['fixes'] += 1

    w, wd = match_road(lat, lng, heading)
    osm_name = w[0] if w else None
    app_name = f.get('street')

    # route veto
    names = route_at(ms)
    sim = None
    if w is not None:
        cand_ok = any(same(n, osm_name or '') for n in names)
        cur_ok = any(same(n, published or '') for n in names)
        if cand_ok or not cur_ok:
            sim = osm_name
        else:
            sim = published
    # hysteresis on the published name
    if sim and published and not same(sim, published):
        if pending and same(pending, sim):
            count += 1
            moved_acc += moved
        else:
            pending, count, moved_acc = sim, 1, moved
        if count >= 2 or moved_acc >= 30:
            published, pending, count, moved_acc = sim, None, 0, 0.0
        else:
            sim = published
    elif sim:
        pending, count, moved_acc = None, 0, 0.0
    if sim:
        published = sim

    if app_name and osm_name and not same(app_name, osm_name):
        stats['before_bad'] += 1
    if sim and osm_name and not same(sim, osm_name):
        stats['after_bad'] += 1
    if app_name and sim and not same(app_name, sim):
        stats['changed'] += 1
        # What the corrected road would show, and the Waze value under the car.
        seg_kmh = seg.query(lat, lng, heading_deg=heading, max_dist_m=MAX_D)[0]
        new_lim = sim_limit(w[1] if w else '',
                            w[3] if w else None, w[4] if w else None, seg_kmh)
        old_lim = f.get('limitEffective')
        if old_lim is not None and new_lim and new_lim != old_lim:
            stats['limit_changed'] = stats.get('limit_changed', 0) + 1
            k = f'{old_lim} -> {new_lim}'
            stats[k] = stats.get(k, 0) + 1
            if seg_kmh and new_lim == seg_kmh:
                stats['now_matches_layer'] = stats.get('now_matches_layer', 0) + 1
        if len(changed_examples) < 10:
            changed_examples.append(
                (hh(ms), app_name, sim, osm_name, f.get('highway'), w[1] if w else '',
                 round(wd, 1) if wd else None, old_lim, new_lim, seg_kmh))
    if app_name and osm_name and not same(app_name, osm_name) and \
            sim and not same(sim, osm_name):
        if len(still_bad) < 6:
            still_bad.append((hh(ms), app_name, sim, osm_name))

n = max(1, stats['fixes'])
print(f"fixes replayed            : {stats['fixes']}")
print(f"  app street != nearest OSM way      : {stats['before_bad']} "
      f"({100*stats['before_bad']/n:.0f}%)")
print(f"  NEW rule  != nearest OSM way       : {stats['after_bad']} "
      f"({100*stats['after_bad']/n:.0f}%)")
print(f"  fixes where the new rule changed the street name : {stats['changed']}")
lc = stats.get('limit_changed', 0)
print(f"  of those, the displayed LIMIT would also change  : {lc}")
for k, v in sorted(stats.items()):
    if ' -> ' in k:
        print(f'      {k:<14} {v:>4} fixes')
if stats.get('now_matches_layer'):
    print(f"  ...and the new limit equals the Waze segment under the car : "
          f"{stats['now_matches_layer']}")
print('\nexamples the new rules change:')
for t, app, sim, osm, ah, oh, wd, old_lim, new_lim, seg_kmh in changed_examples:
    print(f'  {t} app={app!r} ({ah}) -> new={sim!r} ({oh}) | nearest way {wd} m | '
          f'limit {old_lim} -> {new_lim} (waze segment here: {seg_kmh or "none"})')
if still_bad:
    print('\nstill disagreeing with the nearest way (route veto or hysteresis held):')
    for t, app, sim, osm in still_bad:
        print(f'  {t} app={app!r} new={sim!r} nearest={osm!r}')
