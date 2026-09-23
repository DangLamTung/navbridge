#!/usr/bin/env python3
"""Full-stack simulation of NavBridge's road + speed-limit decision chain.

Unlike tool/replay_road_rules.py (which approximates the route's street names
from the drive's own callouts), this harness uses the REAL route:

  1. ROUTE — map-match the driven path with the same OSRM service the app calls
     (`/match/v1/driving`, router.project-osrm.org), cached under /tmp. OSRM's
     step `name` is the OSM way name, which is exactly what `nav.text` /
     `nav.nextText` / `nav.nextNextText` are (lib/services/nav_engine.dart takes
     them from the provider's steps).
  2. ENGINE — port of NavEngine.update(): cumulative route distance, the
     nearest route index per fix, the step-advance loop (`_nextStep` with the
     speed-scaled advance margin), and the derivation
         text     = current step name   ('' -> 'Tiến lên')
         nextText = the step being approached
         nextNextText = the one after it
     so the route veto is fed the same names the app has live.
  3. ROAD — the app's Overpass path (lib/services/overpass.dart): every OSM way
     near the fix scored by `distance + classPenalty + headingPenalty`, divided
     detected via the same-street opposite carriageway, resolved at the RAW fix.
  4. LIMIT — the Waze segment layer (exact reader/scoring from
     tool/waze_segments.py, mirroring pickSegmentCandidate) capping the
     motorbike statutory table (tool/app_rules.py).
  5. DECISION — the app's own veto + hysteresis (tool/app_rules.py), then a
     comparison against what the drive actually logged.

Usage:
    python3 tool/simulate_nav.py [<trip.json>] [--no-osrm] [--limit N]
"""

from __future__ import annotations

import bisect
import datetime
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app_rules import (HEADING_M, NON_DRIVABLE, QUERY_M,  # noqa: E402
                       RoadNameHysteresis, class_penalty, pick_road_name,
                       same_road, sim_limit)
from waze_segments import (Segments, segment_line_angle,  # noqa: E402
                           segment_score)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M = 111320.0
MAX_D = 25.0          # the app's speedLimitAt / segment lookup radius
OSRM = 'https://router.project-osrm.org'
SEG_BIN = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')
DEFAULT_TRIP = os.path.join(
    REPO, 'docs/trips/device/2026-09-21_173329_Chuyến_đi.json')

args = [a for a in sys.argv[1:] if not a.startswith('--')]
flags = {a for a in sys.argv[1:] if a.startswith('--')}
trip_path = args[0] if args else DEFAULT_TRIP
use_osrm = '--no-osrm' not in flags

d = json.load(open(trip_path))
fixes = sorted(d['locations'], key=lambda f: int(f['timestampMs']))
hh = lambda ms: datetime.datetime.fromtimestamp(int(ms) / 1000).strftime('%H:%M:%S')
print(f'trip: {os.path.basename(trip_path)}  ({len(fixes)} fixes)')


# ---------------------------------------------------------------------------
# 1. the real route (OSRM /match — the same service the app uses)
# ---------------------------------------------------------------------------
def osrm_match(pts, cache):
    """Map-match the trace. The public demo server throttles /match hard
    ("Too many trace coordinates" / TooBig) and the cap moves with its load, so
    the batch window is adaptive: start wide, halve on TooBig, grow back on
    success."""
    if os.path.exists(cache):
        return json.load(open(cache))
    chunks, i, w, fails = [], 0, 40, 0
    while i < len(pts) - 1:
        chunk = pts[i:i + w]
        coords = ';'.join(f'{lng:.6f},{lat:.6f}' for lat, lng in chunk)
        url = (f'{OSRM}/match/v1/driving/{coords}'
               '?steps=true&geometries=geojson&overview=full')
        try:
            with urllib.request.urlopen(url, timeout=90) as r:
                j = json.load(r)
        except urllib.error.HTTPError as e:
            body = e.read()[:120]
            if b'TooBig' in body and w > 2:
                w = max(2, w // 2)
                continue
            print(f'  OSRM skipped {len(chunk)} coords at {i}: {body!r}')
            fails += 1
            i += w
            continue
        except Exception as exc:  # noqa: BLE001
            print(f'  OSRM error at {i}: {exc}')
            fails += 1
            i += w
            continue
        sts = []
        for m in j.get('matchings') or []:
            for leg in m.get('legs') or []:
                sts.extend(leg.get('steps') or [])
        if sts:
            chunks.append({'steps': sts})
        if w < 40 and fails == 0:
            w = min(40, w * 2)     # recover the wide window once it is accepted
        i += max(1, len(chunk) - 1)  # next window starts where this one ended
    print(f'  OSRM batches: window={w}, failed batches={fails}, '
          f'steps={sum(len(c["steps"]) for c in chunks)}')
    json.dump(chunks, open(cache, 'w'))
    return chunks


chunks = osrm_match(
    [((f.get('latitudeE7') or 0) / 1e7, (f.get('longitudeE7') or 0) / 1e7)
     for f in fixes if f.get('latitudeE7')],
    os.path.join('/tmp', 'osrm_match_' + os.path.basename(trip_path) + '.json'),
) if use_osrm else []


def _hav(a, b):
    dy = (b[0] - a[0]) * M
    dx = (b[1] - a[1]) * M * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


# Build one continuous route polyline out of the per-step geometries, recording
# where each step starts/ends along it — that arc length is what the engine tracks.
ROUTE, STEPS, S_END = [], [], []
_acc = 0.0
for ch in chunks:
    for st in ch['steps']:
        coords = (st.get('geometry') or {}).get('coordinates') or []
        pts = [(c[1], c[0]) for c in coords]
        if ROUTE and pts and _hav(ROUTE[-1], pts[0]) < 0.01:
            pts = pts[1:]
        if not pts:
            continue
        start = _acc
        for p in pts:
            if ROUTE:
                _acc += _hav(ROUTE[-1], p)
            ROUTE.append(p)
        S_END.append(_acc)
        STEPS.append({'name': st.get('name') or '', 'start': start, 'end': _acc})

print(f'  route: {len(STEPS)} steps, {len(ROUTE)} geometry points, '
      f'{_acc / 1000.0:.2f} km')


def project(s_lat, s_lng):
    """Nearest point on the route polyline -> arc length along it."""
    ml = M * math.cos(math.radians(s_lat))
    px, py = s_lng * ml, s_lat * M
    best, best_s, run = float('inf'), 0.0, 0.0
    for i in range(len(ROUTE) - 1):
        a, b = ROUTE[i], ROUTE[i + 1]
        ax, ay = a[1] * ml, a[0] * M
        bx, by = b[1] * ml, b[0] * M
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        ln_ = math.sqrt(l2)
        if l2 > 1e-9:
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
            dd = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if dd < best:
                best, best_s = dd, run + t * ln_
        run += ln_
    return best_s, best


def engine_names_for(s_along, speed_mps):
    """NavEngine.update(): `text` is the step being travelled, `nextText` the
    step after its maneuver, and the step flips once the maneuver is within the
    speed-scaled advance margin (max(3 m, 0.8 s)) — lib/services/nav_engine.dart.
    """
    if not STEPS:
        return None, 0
    i = bisect.bisect_left(S_END, s_along)
    i = max(0, min(i, len(STEPS) - 1))
    advance = max(3.0, speed_mps * 0.8)
    if i < len(STEPS) - 1 and S_END[i] - s_along < advance:
        i += 1
    nm = lambda k: (STEPS[k]['name'] if 0 <= k < len(STEPS) else '')  # noqa: E731
    return ({'text': nm(i) or 'Tiến lên', 'next': nm(i + 1), 'nextNext': nm(i + 2)},
            S_END[i] - s_along)


# ---------------------------------------------------------------------------
# 3. the app's Overpass road path, over ways fetched once for the bbox
# ---------------------------------------------------------------------------
la = [((f.get('latitudeE7') or 0) / 1e7) for f in fixes if f.get('latitudeE7')]
ln = [((f.get('longitudeE7') or 0) / 1e7) for f in fixes if f.get('longitudeE7')]
bbox = (min(la) - 0.004, min(ln) - 0.004, max(la) + 0.004, max(ln) + 0.004)
OSM_CACHE = f'/tmp/osm_ways_{bbox[0]:.3f}_{bbox[2]:.3f}.json'
if os.path.exists(OSM_CACHE):
    osm = json.load(open(OSM_CACHE))
else:
    q = (f'[out:json][timeout:120];way({bbox[0]},{bbox[1]},{bbox[2]},{bbox[3]})'
         '["highway"];out tags geom;')
    req = urllib.request.Request(
        OSRM.replace('/match/v1', '') and
        'https://overpass-api.de/api/interpreter',
        data=urllib.parse.urlencode({'data': q}).encode(),
        headers={'User-Agent': 'navbridge-dev/1.0 (nav simulation)'},
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        osm = json.load(r)
    json.dump(osm, open(OSM_CACHE, 'w'))

WAYS = []
for e in osm['elements']:
    g = e.get('geometry') or []
    t = e.get('tags', {})
    if len(g) >= 2 and t.get('highway'):
        WAYS.append({'id': e['id'], 'name': t.get('name'), 'hw': t.get('highway'),
                     'oneway': t.get('oneway'), 'lanes': t.get('lanes'),
                     'maxspeed': t.get('maxspeed'), 'geom': g})
print(f'  ways: {len(WAYS)} OSM highway ways in the trip bbox')


def geom_stats(lat, lng, geom):
    """(distance, bearing, overshoot) — the same measurements as the layer pick."""
    ml = M * math.cos(math.radians(lat))
    px, py = lng * ml, lat * M
    best, bearing, over = float('inf'), 0.0, 0.0
    for i in range(len(geom) - 1):
        a, b = geom[i], geom[i + 1]
        ax, ay = a['lon'] * ml, a['lat'] * M
        bx, by = b['lon'] * ml, b['lat'] * M
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
GRID = {}
for w in WAYS:
    for p in w['geom']:
        GRID.setdefault((int(p['lat'] // CELL), int(p['lon'] // CELL)),
                        []).append(w)

# lib/services/overpass.dart _classPriority / _isDrivable live in tool/app_rules.py
# (class_penalty, NON_DRIVABLE, QUERY_M), so both harnesses score ways identically.


def road_at(lat, lng, heading):
    """fetchRoadInfo(): prefer drivable ways, then
    distance + class penalty (priority*8) + heading penalty, exactly as the app."""
    gy, gx = int(lat // CELL), int(lng // CELL)
    cands = []
    seen = set()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            for w in GRID.get((gy + dy, gx + dx), ()):
                if w['id'] in seen:
                    continue
                dd, brg, _ = geom_stats(lat, lng, w['geom'])
                if dd <= QUERY_M:
                    seen.add(w['id'])
                    cands.append((w, dd, brg))
    if not cands:
        return None
    pool = [c for c in cands if c[0]['hw'] not in NON_DRIVABLE]
    pool = pool or cands          # the app falls back to everything
    best, best_score = None, float('inf')
    for w, dd, brg in pool:
        score = dd + class_penalty(w['hw'])
        if heading:
            score += segment_line_angle(heading, brg) / 90.0 * HEADING_M
        if score < best_score:
            best_score, best = score, (w, dd)
    return best


def divided_here(w, lat, lng):
    """_hasOppositeCarriageway(): another way of the same street running the
    other way within ~35 m."""
    if not w['name']:
        return False
    for o in WAYS:
        if o is w or not same_road(o['name'] or '', w['name'] or ''):
            continue
        dd, _, _ = geom_stats(lat, lng, o['geom'])
        if dd <= 35.0:
            return True
    return False


# ---------------------------------------------------------------------------
# 4/5. replay: layer + road + veto + hysteresis
# ---------------------------------------------------------------------------
seg = Segments(SEG_BIN)
INTO_RX = re.compile(r'vào ([^.,]+)')


def callout_names(t):
    m = re.match(r'^Đi trên (.+?), sau .*', t)
    n = INTO_RX.search(t)
    return {x for x in (m.group(1) if m else None, n.group(1) if n else None) if x}


callout_route = []
for a in sorted(d['announcements'], key=lambda a: int(a['timestampMs'])):
    if a.get('kind') == 'maneuver':
        names = callout_names(a.get('text') or '')
        if names:
            callout_route.append((int(a['timestampMs']), names))


def callout_at(ms):
    out = set()
    for t, names in callout_route:
        if t <= ms:
            out = names
        else:
            break
    return out


hyst = RoadNameHysteresis()
published = None
prev = None
stats = {'fixes': 0, 'before_bad': 0, 'after_bad': 0, 'name_changed': 0,
         'limit_changed': 0, 'now_matches_layer': 0, 'veto_blocked': 0,
         'hyst_held': 0, 'veto_saved_bad': 0, 'route_n': 0,
         'app_vs_route': 0, 'sim_vs_route': 0, 'pick_vs_route': 0,
         'seg_off_road': 0, 'seg_off_road_limit': 0, 'layer_limit_dropped': 0}
deltas = {}
examples = []
resid = []
seg_off = []
odds = []
s_along = 0.0
route_names = []
agree = {'n': 0, 'ok': 0}
name_seq = []        # (ms, published name) for the oscillation metric

for f in fixes:
    lat = (f.get('latitudeE7') or 0) / 1e7
    lng = (f.get('longitudeE7') or 0) / 1e7
    if not lat:
        continue
    ms = int(f['timestampMs'])
    heading = f.get('heading')
    speed = float(f.get('velocity') or 0.0)
    moved = 0.0
    if prev:
        moved = math.hypot((lat - prev[0]) * M,
                           (lng - prev[1]) * M * math.cos(math.radians(lat)))
    prev = (lat, lng)
    stats['fixes'] += 1

    s_along, _ = project(lat, lng) if STEPS else (0.0, 0.0)
    eng, to_maneuver = engine_names_for(s_along, speed) if STEPS else (None, 0)
    if eng is None:
        names = callout_at(ms)
    else:
        names = {x for x in (eng['text'], eng['next'], eng['nextNext']) if x}
        route_names.append(names)
        co_names = callout_at(ms)
        if co_names:
            agree['n'] += 1
            if any(same_road(a, b) for a in names for b in co_names):
                agree['ok'] += 1

    # road (Overpass path, raw fix); the layer query is kept for the limit step
    # below, which needs the settled road name first.
    hit = road_at(lat, lng, heading)
    w = hit[0] if hit else None
    seg_q = seg.query(lat, lng, heading_deg=heading, max_dist_m=MAX_D)
    seg_kmh, seg_street = seg_q[0], seg_q[1]

    # the app's route veto + hysteresis
    sim = None
    if w is not None:
        cand_ok = any(same_road(n, w['name'] or '') for n in names)
        cur_ok = any(same_road(n, published or '') for n in names)
        sim = pick_road_name(published or '', w['name'] or '', cand_ok, cur_ok)
        if published and sim and not same_road(sim, published):
            if not hyst.accept(published, sim, moved):
                sim = published
                stats['hyst_held'] += 1
        else:
            hyst.reset()
        if published and sim and same_road(sim, published) \
                and not same_road(w['name'] or '', published):
            # the veto kept a name that is NOT the nearest way (a crossing road)
            stats['veto_blocked'] += 1
            if same_road(published, f.get('street') or ''):
                stats['veto_saved_bad'] += 1
        if sim:
            published = sim
            name_seq.append((ms, sim))

    # The layer's value is only usable for the road we are displaying: a named
    # segment that contradicts the settled name is a different street, and its
    # limit belongs to that street (postedLimitMatchesName, road_match.dart).
    new_limit = None
    posted = seg_kmh
    if seg_street and sim and not same_road(seg_street, sim):
        posted = None
        stats['layer_limit_dropped'] += 1
    if w is not None:
        new_limit = sim_limit(w['hw'], w['oneway'], w['lanes'], posted=posted,
                              divided=divided_here(w, lat, lng))

    app_name = f.get('street')
    osm_name = w['name'] if w else None
    if app_name and osm_name and not same_road(app_name, osm_name):
        stats['before_bad'] += 1
    if published and osm_name and not same_road(published, osm_name):
        stats['after_bad'] += 1

    # Ground truth: the map-matched route's own current-step name — where the
    # trace actually runs, independent of any road-class preference.
    route_text = (eng or {}).get('text') or ''
    if route_text and route_text != 'Tiến lên' and app_name:
        stats['route_n'] += 1
        if not same_road(route_text, app_name):
            stats['app_vs_route'] += 1
        if sim and not same_road(route_text, sim):
            stats['sim_vs_route'] += 1
        if osm_name and not same_road(route_text, osm_name):
            stats['pick_vs_route'] += 1
        # A segment the car is not on can still supply the LIMIT: the name veto
        # rewrites the displayed street, but the value travels with the segment
        # record. Flag where the settled name and the segment's own street
        # disagree, which means the chip pairs road A's name with road B's limit.
        if seg_street and sim and not same_road(seg_street, sim):
            stats['seg_off_road'] += 1
            if new_limit and new_limit != f.get('limitEffective'):
                stats['seg_off_road_limit'] += 1
                if len(seg_off) < 8:
                    seg_off.append((hh(ms), sim, seg_street, seg_kmh,
                                    route_text, new_limit,
                                    f.get('limitEffective'), lat, lng))
        if sim and not same_road(route_text, sim) and len(resid) < 12:
            resid.append((hh(ms), app_name, sim, route_text,
                          w['name'] if w else None, w['hw'] if w else ''))
    if app_name and sim and not same_road(app_name, sim):
        stats['name_changed'] += 1
        old_lim = f.get('limitEffective')
        if old_lim and new_limit and old_lim != new_limit:
            stats['limit_changed'] += 1
            k = f'{old_lim} -> {new_limit}'
            deltas[k] = deltas.get(k, 0) + 1
            if seg_kmh and new_limit == seg_kmh:
                stats['now_matches_layer'] += 1
        if len(examples) < 8 and not same_road(app_name or '', route_text):
            examples.append((hh(ms), app_name, sim, route_text,
                             w['name'] if w else None, w['hw'] if w else '',
                             f.get('limitEffective'), new_limit, seg_kmh))
    if new_limit and (new_limit <= 20 or new_limit >= 80) and len(odds) < 6:
        odds.append((hh(ms), lat, lng, w['name'] if w else None,
                     w['hw'] if w else '', new_limit, seg_kmh))

n = max(1, stats['fixes'])
src = 'OSRM route steps (real nav.text/nextText)' if STEPS \
    else 'callout reconstruction'
print(f'\nroute names from          : {src}')
if agree['n']:
    print(f'  route names agree with the drive\'s own callouts : '
          f'{agree["ok"]}/{agree["n"]} ({100*agree["ok"]/agree["n"]:.0f}%)')
rn = max(1, stats['route_n'])
print(f'ground truth = the matched route step name '
      f'({stats["route_n"]} named fixes)')
print(f'  app street  != route step : {stats["app_vs_route"]} '
      f'({100*stats["app_vs_route"]/rn:.0f}%)')
print(f'  simulated   != route step : {stats["sim_vs_route"]} '
      f'({100*stats["sim_vs_route"]/rn:.0f}%)')
print(f'  Overpass pick != route step : {stats["pick_vs_route"]} '
      f'({100*stats["pick_vs_route"]/rn:.0f}%)  <- class penalty prefers'
      ' the bigger road')
print(f'fixes replayed            : {stats["fixes"]}')
print(f'  app street != the way at the car      : {stats["before_bad"]} '
      f'({100*stats["before_bad"]/n:.0f}%)')
print(f'  simulated  != the way at the car      : {stats["after_bad"]} '
      f'({100*stats["after_bad"]/n:.0f}%)')
print(f'  street name corrected                 : {stats["name_changed"]}')
print(f'  displayed limit changed               : {stats["limit_changed"]}')
for k, v in sorted(deltas.items(), key=lambda kv: -kv[1]):
    print(f'      {k:<12} {v:>4}')
print(f'  new limit equals the Waze segment     : {stats["now_matches_layer"]}')
print(f'  veto kept the published name over the nearest way : '
      f'{stats["veto_blocked"]}')
print(f'  of those, name also matched the app\'s (right) one : '
      f'{stats["veto_saved_bad"]}')
print(f'  hysteresis held a name back                       : '
      f'{stats["hyst_held"]}')
print(f'  layer limit dropped (segment street != shown road): '
      f'{stats["layer_limit_dropped"]}')

# Oscillations: A -> B -> A inside 4 fixes, i.e. the label flipping back and
# forth (the app's own log shows 28 of these on the 2026-09-22 18:03 drive).
collapsed = []
for ms, nm in name_seq:
    if not collapsed or collapsed[-1][1] != nm:
        collapsed.append((ms, nm))
osc = 0
prev = None
for i in range(1, len(collapsed) - 1):
    if collapsed[i][1] != collapsed[i - 1][1] \
            and collapsed[i + 1][1] == collapsed[i - 1][1]:
        osc += 1
app_osc = 0
prev = None
app_seq = []
for f in fixes:
    nm = f.get('street')
    if nm and (not app_seq or app_seq[-1][1] != nm):
        app_seq.append((int(f['timestampMs']), nm))
for i in range(1, len(app_seq) - 1):
    if app_seq[i][1] != app_seq[i - 1][1] \
            and app_seq[i + 1][1] == app_seq[i - 1][1]:
        app_osc += 1
print(f'  name changes: app {len(app_seq) - 1}, simulated '
      f'{len(collapsed) - 1};  oscillations: app {app_osc}, sim {osc}')
if odds:
    print('\nsuspicious limits (needs a look):')
    for t, ola, oln, on, hw, nl, sk in odds:
        print(f'  {t} {ola:.5f},{oln:.5f} {on!r} {hw} -> {nl} (waze {sk or "none"})')
if resid:
    print('\nresidual mismatches (sim != route):')
    for t, app, sim, rt, pick, hw in resid:
        print(f'  {t} sim={sim!r} route={rt!r} app={app!r} '
              f'(overpass pick {pick!r} {hw})')

if stats['seg_off_road']:
    print(f'  segment named a DIFFERENT street than displayed : '
          f'{stats["seg_off_road"]}')
    print(f'  ...and it changed the limit shown               : '
          f'{stats["seg_off_road_limit"]}')
    for t, shown, ss, sk, rt, nl, old, la, ln in seg_off:
        print(f'    {t} shown {shown!r} but segment {ss!r} ({sk} km/h) '
              f'[route {rt!r}] -> limit {old} => {nl} '
              f'@ {la:.5f},{ln:.5f}')

if examples:
    print('\nexamples (app street disagreed with the route):')
    for t, app, sim, rt, pick, hw, old, new, sk in examples:
        print(f'  {t} app={app!r} -> sim={sim!r} route={rt!r} '
              f'(overpass pick {pick!r} {hw}) limit {old} -> {new} '
              f'(waze {sk or "none"})')
