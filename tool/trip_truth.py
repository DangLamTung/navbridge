#!/usr/bin/env python3
"""Build the reference dataset for a recorded NavBridge trip, with the WA‑ZE
SEGMENT layer as ground truth.

Ground truth
    `assets/offline_map/waze_segments.bin` — the per-segment posted-limit layer
    the app queries FIRST (`speedLimitAt`). For every recorded fix this tool
    looks up the limit on the segment under the car (same 25 m radius, same
    heading-based fwd/rev choice) and vehicle-caps it exactly like the app does
    (`_correctSpeedFromWaze` → `effectiveLimit(highway, vehicle, tagged)`).
    When the segment layer has nothing there it falls back to the Waze/VietMap
    point layers, then to the value the reference run's own log recorded, and
    the fix carries that source: segment | point | log-road | none.

    A `speed` point in the sign index is NOT authority over the segment layer.
    It is only recorded, with a reason: whether it sits on the segment the car
    is currently on (`sign_on_same_segment`) or belongs to another street
    (`sign_other_segment`) — the latter is the Vườn Lài case, where a 60 that
    belongs to Lũy Bán Bích was applied to Vườn Lài.

Assertion target
    `expected_limit` = the segment-layer limit, vehicle-capped. There is no
    second source: the "khu đông dân cư" boundary ceiling is GONE (9,211
    boundary points that never fired on any recorded drive and override a
    posted segment value 39% of the time they land on one — see
    tool/why_drop_kdc.py and droppedSignKinds in
    lib/services/offline_road_signs.dart), so posted signs + the road's own
    value are the whole limit model.

Also computed, and reported
  * `app_limit` — what the app does today (trusting every `speed` entry in the
    shipped sign index, road association frozen at adoption time). The fixes
    where it differs from `expected_limit` are `divergence[]`.
  * parser validation: how often the offline segment lookup reproduces the
    limit the reference run logged (`speedLimit`), which is the app's own
    `speedLimitAt` result. Low agreement would mean this parser is wrong, not
    that the app is.

Output
    docs/trip_truth_<name>.json + .js (`window.TRUTH_DATA`)

Usage
    python3 tool/trip_truth.py "docs/trips/device/2026-09-18_172234_Chuyến_đi.json"
    ... --vehicle car --json-only --inventory
"""
from __future__ import annotations

import argparse
import bisect
import json
import math
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from waze_segments import Segments  # noqa: E402

M_PER_DEG_LAT = 111320.0
ON_ROUTE_MAX_OFF_M = 200.0   # mirror of offline_geo.dart:nearestAlong
SEG_MAX_DIST_M = 25.0        # mirror of speedLimitAt(maxDistM: 25)

# Mirror of lib/services/overpass.dart statutoryLimit().
STATUTORY = {
    'car': {'motorway': 120, 'motorway_link': 100, 'trunk': 90, 'trunk_link': 80,
            'primary': 80, 'primary_link': 60, 'secondary': 60,
            'secondary_link': 50, 'tertiary': 50, 'tertiary_link': 50,
            'unclassified': 50, 'residential': 50, 'living_street': 20,
            'service': 30, 'pedestrian': 10, 'footway': 10, 'cycleway': 20},
    'motorbike': {'motorway': 80, 'motorway_link': 60, 'trunk': 60,
                  'trunk_link': 50, 'primary': 60, 'primary_link': 50,
                  'secondary': 60, 'secondary_link': 50, 'tertiary': 60,
                  'tertiary_link': 50, 'unclassified': 50, 'residential': 50,
                  'living_street': 20, 'service': 30, 'pedestrian': 10,
                  'footway': 10, 'cycleway': 20},
    'truck': {'motorway': 80, 'motorway_link': 70, 'trunk': 70, 'trunk_link': 60,
              'primary': 60, 'primary_link': 50, 'secondary': 50,
              'secondary_link': 40, 'tertiary': 50, 'tertiary_link': 40,
              'unclassified': 40, 'residential': 40, 'living_street': 20,
              'service': 30, 'pedestrian': 10, 'footway': 10, 'cycleway': 20},
}

ADOPT_M = 400.0   # app adopts a sign this far before reaching it
SIGN_REACHED_M = 50.0  # mirror of kSignReachedM (lib/core/sign_limit.dart)
STABLE_S = 2.0    # "Giới hạn N" waits for the value to be stable this long
COOLDOWN_S = 4.0  # ... and never repeats within this window
UPCOMING_M = 50.0


def urban_limit(vehicle: str, divided: bool = False) -> int:
    if vehicle == 'truck':
        return 50 if divided else 40
    return 60 if divided else 50


def effective_limit(highway: str, vehicle: str, tagged_kmh: int = 0,
                    oneway=None, lanes=None, divided: bool = False) -> int:
    """Mirror of overpass.dart:effectiveLimit."""
    table = STATUTORY.get(vehicle, STATUTORY['car'])
    if highway in ('residential', 'unclassified'):
        return urban_limit(vehicle, divided)
    statutory = table.get(highway, 50)
    if tagged_kmh <= 0:
        return statutory
    return tagged_kmh if vehicle == 'car' else min(statutory, tagged_kmh)


def meters(a, b) -> float:
    dlat = (b[0] - a[0]) * M_PER_DEG_LAT
    dlng = (b[1] - a[1]) * M_PER_DEG_LAT * math.cos(math.radians(a[0]))
    return math.hypot(dlat, dlng)


def key5(lat, lng):
    return (round(float(lat), 5), round(float(lng), 5))


class Track:
    """Recorded polyline + along-distance projection index."""

    def __init__(self, pts):
        self.pts = pts
        self.cum = [0.0]
        for i in range(1, len(pts)):
            self.cum.append(self.cum[-1] + meters(pts[i - 1], pts[i]))
        self.cell = 0.002
        self.grid = {}
        for i in range(len(pts) - 1):
            for k in self._cells(pts[i], pts[i + 1]):
                self.grid.setdefault(k, []).append(i)

    def _cells(self, a, b):
        c = self.cell
        lat0, lat1 = sorted((a[0], b[0]))
        lng0, lng1 = sorted((a[1], b[1]))
        return [(gy, gx)
                for gy in range(int(math.floor(lat0 / c)),
                                int(math.floor(lat1 / c)) + 1)
                for gx in range(int(math.floor(lng0 / c)),
                                int(math.floor(lng1 / c)) + 1)]

    def project(self, lat, lng):
        c = self.cell
        gy, gx = int(math.floor(lat / c)), int(math.floor(lng / c))
        best_off, best_along = float('inf'), 0.0
        seen = set()
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                for i in self.grid.get((gy + dy, gx + dx), ()):
                    if i in seen:
                        continue
                    seen.add(i)
                    a, b = self.pts[i], self.pts[i + 1]
                    ax, ay = a[1], a[0]
                    bx, by = b[1], b[0]
                    dx2, dy2 = bx - ax, by - ay
                    l2 = dx2 * dx2 + dy2 * dy2
                    t = 0.0 if l2 == 0 else max(
                        0.0, min(1.0, ((lng - ax) * dx2 + (lat - ay) * dy2) / l2))
                    px, py = ax + t * dx2, ay + t * dy2
                    off = math.hypot(
                        (lng - px) * M_PER_DEG_LAT * math.cos(math.radians(lat)),
                        (lat - py) * M_PER_DEG_LAT)
                    if off < best_off:
                        best_off = off
                        best_along = self.cum[i] + t * (self.cum[i + 1]
                                                       - self.cum[i])
        if best_off > ON_ROUTE_MAX_OFF_M:
            return None
        return best_along, best_off


def load_signs(path: str):
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    out = []
    for s in data.get('signs', []):
        try:
            lat, lng = float(s['lat']), float(s['lng'])
        except (KeyError, TypeError, ValueError):
            continue
        out.append({'lat': lat, 'lng': lng, 'kind': s.get('kind') or '',
                    'value': s.get('value'), 'source': s.get('source') or '',
                    'name': s.get('name') or ''})
    return out


def load_speed_points(*paths):
    out = []
    for p in paths:
        if not os.path.exists(p):
            continue
        with open(p, encoding='utf-8') as fh:
            doc = json.load(fh)
        for pt in doc.get('points', []):
            if pt.get('lat') is None or pt.get('lng') is None:
                continue
            kmh = int(pt.get('kmh') or 0)
            if kmh:
                out.append({'lat': float(pt['lat']), 'lng': float(pt['lng']),
                            'kmh': kmh, 'from': os.path.basename(p)})
    return out


class PointIndex:
    CELL = 0.002

    def __init__(self, items):
        from collections import defaultdict
        self.items = items
        self.grid = defaultdict(list)
        for i, it in enumerate(items):
            self.grid[(int(math.floor(it['lat'] / self.CELL)),
                       int(math.floor(it['lng'] / self.CELL)))].append(i)

    def nearest(self, lat, lng):
        gy = int(math.floor(lat / self.CELL))
        gx = int(math.floor(lng / self.CELL))
        best, best_d = None, float('inf')
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for i in self.grid.get((gy + dy, gx + dx), ()):
                    it = self.items[i]
                    d = math.hypot((it['lat'] - lat) * M_PER_DEG_LAT,
                                   (it['lng'] - lng) * M_PER_DEG_LAT
                                   * math.cos(math.radians(lat)))
                    if d < best_d:
                        best, best_d = it, d
        return best, best_d


def load_trip(path: str):
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
    fixes = []
    for loc in data.get('locations', []):
        try:
            lat = float(loc['latitudeE7']) / 1e7
            lng = float(loc['longitudeE7']) / 1e7
        except (KeyError, TypeError, ValueError):
            continue
        fixes.append({
            't': loc.get('timestamp') or '',
            'tMs': int(loc.get('timestampMs') or 0),
            'lat': lat, 'lng': lng,
            'heading': loc.get('heading'),
            'speed_mps': float(loc.get('velocity') or 0),
            'street': loc.get('street'),
            'highway': loc.get('highway'),
            'road_limit': loc.get('speedLimit'),
            'old_effective': loc.get('limitEffective'),
            'announcements': [],
        })
    for a in data.get('announcements', []):
        t = int(a.get('timestampMs') or 0)
        for fx in fixes:
            if abs(fx['tMs'] - t) <= 1500:
                fx['announcements'].append({'kind': a.get('kind'),
                                            'text': a.get('text')})
                break
    return data, fixes


def ground_truth(fixes, segs: Segments, pt_index: PointIndex, vehicle: str):
    """Per-fix segment-layer reference, vehicle-capped like the app does."""
    rows = []
    for f in fixes:
        heading = f['heading'] if isinstance(f['heading'], (int, float)) else None
        kmh, street, cls, sep, dist, seg_id = segs.query(
            f['lat'], f['lng'], heading, SEG_MAX_DIST_M)
        src = 'segment' if kmh else 'none'
        raw = kmh
        pt_from = None
        if not raw:
            pt, pd = pt_index.nearest(f['lat'], f['lng'])
            if pt and pd <= SEG_MAX_DIST_M:
                raw, src, pt_from = pt['kmh'], 'point', pt['from']
        if raw:
            limit = effective_limit(f['highway'] or 'unclassified', vehicle,
                                    tagged_kmh=raw, divided=sep)
        else:
            # The segment and point layers have nothing here — the app falls
            # back to its graph/statutory estimate, which is what the reference
            # log recorded. Weaker evidence; marked as such.
            limit = f['road_limit'] or 0
            src = 'log-road' if limit else 'none'
        rows.append({
            'limit': limit, 'source': src, 'raw': raw,
            'seg_kmh': kmh, 'seg_street': street, 'seg_class': cls,
            'seg_sep': sep, 'seg_dist': dist, 'seg_id': seg_id,
            'pt_from': pt_from,
        })
    return rows


def simulate(fixes, cum, on_track_signs, gt_rows, vehicle):
    """Resolve the expected limit per fix from the ground truth, plus the
    sign-adoption trace for reporting.

    The expected limit IS the ground truth: the app's only other source was the
    "khu đông dân cư" boundary layer, which has been removed (its per-segment
    boundary points were wrong most of the time and could rewrite the limit
    from a single bogus point — see droppedSignKinds in
    lib/services/offline_road_signs.dart).
    """
    speed_signs = sorted([s for s in on_track_signs
                          if s['kind'] == 'speed' and s['value']],
                         key=lambda s: s['along'])
    speed_alongs = [s['along'] for s in speed_signs]

    rows, events, sign_notes = [], [], []
    last_spoken = pending = pending_since = last_spoke_t = None

    for i, fx in enumerate(fixes):
        s, gt = cum[i], gt_rows[i]
        base, source = gt['limit'], gt['source']

        # 1. which speed sign the app would have ADOPTED (≤400 m ahead), and
        #    whether it belongs to the segment the car is on.
        sign_used, sign_ahead, sign_reason = None, 0.0, None
        if speed_alongs:
            j = bisect.bisect_left(speed_alongs, s)
            if j < len(speed_signs):
                cand = speed_signs[j]
                gap = cand['along'] - s
                if gap <= ADOPT_M:
                    sign_ahead = gap
                    if cand.get('seg_id') is not None and \
                            cand['seg_id'] == gt['seg_id']:
                        sign_used = cand
                        sign_reason = 'same-segment'
                    else:
                        sign_reason = ('other-segment' if cand.get('seg_id')
                                       is not None else 'no-segment')

        # 2. nothing else applies: the expected limit is the ground truth.
        limit = base

        if sign_used:
            capped = effective_limit(fx['highway'] or 'unclassified', vehicle,
                                     tagged_kmh=sign_used['value'])
            if capped != gt['raw']:
                sign_notes.append({
                    'i': i, 's_m': round(s, 1), 'sign': sign_used['value'],
                    'sign_capped': capped, 'segment': gt['raw'],
                    'street': gt['seg_street'],
                    'verdict': 'sign lower' if capped < (gt['raw'] or 0)
                    else 'sign higher',
                })
        elif sign_reason and not sign_used:
            pass

        upcoming = limit > 0 and sign_ahead > UPCOMING_M and sign_used is not None
        rows.append({
            'limit': limit, 'source': source, 'expected_sign_ahead': sign_ahead,
            'sign_reason': sign_reason,
            'sign_value': sign_used['value'] if sign_used else None,
            'upcoming': upcoming,
            'gt_limit': gt['limit'], 'gt_source': gt['source'],
            'seg_kmh': gt['seg_kmh'], 'seg_street': gt['seg_street'],
        })

        if limit > 0:
            t_s = fx['tMs'] / 1000.0
            if limit == last_spoken:
                pending = pending_since = None
            elif limit != pending:
                pending, pending_since = limit, t_s
            elif (pending_since is not None
                  and t_s - pending_since >= STABLE_S
                  and (last_spoke_t is None or t_s - last_spoke_t >= COOLDOWN_S)):
                last_spoke_t, last_spoken = t_s, limit
                pending = pending_since = None
                events.append({'i': i, 't': fx['t'], 's_m': round(s, 1),
                               'limit': limit, 'source': source,
                               'upcoming': upcoming,
                               'text': (f'Tốc độ tối đa tiếp theo {limit} km/h'
                                        if upcoming else f'Giới hạn {limit} km/h')})
    return rows, events, speed_signs, sign_notes


def simulate_app(fixes, cum, on_track_signs, vehicle, reached_only=False):
    """Mirror of the app's sign handling.

    `reached_only=False` reproduces the build that recorded the 09-18 drive:
    a sign adopted up to 400 m early takes effect immediately, and its road is
    frozen at adoption time (null road ⇒ applies for the whole drive).

    `reached_only=True` reproduces the FIX (lib/core/sign_limit.dart): a sign
    is preview-only until the car reaches it, and its road is bound as soon as
    a name is known.
    """
    speed_signs = sorted([s for s in on_track_signs
                          if s['kind'] == 'speed' and s['value']],
                         key=lambda s: s['along'])
    alongs = [s['along'] for s in speed_signs]
    sign_limit, sign_road, sign_ahead = None, None, 0.0
    rows = []
    for i, fx in enumerate(fixes):
        s = cum[i]
        if alongs:
            j = bisect.bisect_left(alongs, s)
            if j < len(speed_signs):
                cand = speed_signs[j]
                gap = cand['along'] - s
                if gap <= ADOPT_M:
                    sign_ahead = gap
                    if cand['value'] != sign_limit:
                        sign_limit = cand['value']
                        sign_road = fx['street']  # frozen here, may be None
                else:
                    sign_ahead = 0.0
        if reached_only:
            reached = sign_ahead <= SIGN_REACHED_M
            # bind the sign to the road it stands on once the name is known
            if (sign_limit is not None and reached
                    and (sign_road is None or sign_road == '')
                    and fx['street']):
                sign_road = fx['street']
            applies = (sign_limit is not None and reached
                       and (not sign_road or sign_road == fx['street']))
        else:
            applies = sign_limit is not None and (not sign_road
                                                  or sign_road == fx['street'])
        capped = effective_limit(fx['highway'] or 'unclassified', vehicle,
                                 tagged_kmh=sign_limit) if applies else None
        if capped is not None:
            limit, source = capped, 'sign'
        else:
            limit, source = (fx['road_limit'] or 0), 'road'
        rows.append({'limit': limit, 'source': source, 'sign': sign_limit,
                     'sign_road': sign_road,
                     'upcoming': source == 'sign' and sign_ahead > UPCOMING_M})
    return rows


def build(trip_path, signs_path, vehicle, segments_path,
          waze_points, vietmap_points, verbose=True, segs=None):
    _data, fixes = load_trip(trip_path)
    track = Track([(f['lat'], f['lng']) for f in fixes])
    total_m = track.cum[-1]

    if segs is None:
        segs = Segments(segments_path, verbose=verbose)
    pt_index = PointIndex(load_speed_points(waze_points, vietmap_points))
    gt_rows = ground_truth(fixes, segs, pt_index, vehicle)

    signs = load_signs(signs_path)
    on_track = []
    for s in signs:
        pr = track.project(s['lat'], s['lng'])
        if pr is None:
            continue
        kmh, street, cls, sep, sdist, sid = segs.query(s['lat'], s['lng'])
        on_track.append(dict(s, along=pr[0], off=pr[1], seg_id=sid,
                             seg_street=street, seg_kmh=kmh, seg_dist=sdist))

    rows, events, used_signs, sign_notes = simulate(
        fixes, track.cum, on_track, gt_rows, vehicle)
    app_rows = simulate_app(fixes, track.cum, on_track, vehicle)
    fixed_rows = simulate_app(fixes, track.cum, on_track, vehicle,
                              reached_only=True)

    # --- validation: does the offline lookup reproduce the app's own value? --
    same_raw = sum(1 for f, g in zip(fixes, gt_rows)
                   if g['seg_kmh'] and g['seg_kmh'] == f['road_limit'])
    same_all = sum(1 for f, g in zip(fixes, gt_rows)
                   if g['limit'] and g['limit'] == f['road_limit'])
    seg_hit = sum(1 for g in gt_rows if g['seg_kmh'])
    if verbose:
        print(f'track            : {len(fixes)} fixes, {total_m:.0f} m '
              f'({total_m / 1000:.2f} km)')
        print(f'segment lookup    : value on {seg_hit}/{len(fixes)} '
              f'fixes ({100.0 * seg_hit / len(fixes):.1f}%) within '
              f'{SEG_MAX_DIST_M:.0f} m')
        print(f'  reproduces the reference run\'s logged speedLimit: '
              f'{same_all}/{len(fixes)} ({100.0 * same_all / len(fixes):.1f}%) '
              f'[uncapped segment == log: {same_raw}]')
        print(f'ground-truth source: '
              f'{dict(Counter(g["source"] for g in gt_rows))}')
        print(f'  speed signs on the track: {len(used_signs)} '
              f'({sum(1 for s in used_signs if s.get("seg_id") is not None)} '
              f'with a segment under them)')

    fix_out, diverge = [], []
    for n, f in enumerate(fixes):
        r, a, g = rows[n], app_rows[n], gt_rows[n]
        if r['limit'] != a['limit']:            diverge.append({
                'i': n, 't': f['t'], 's_m': r['s_m'] if 's_m' in r
                else round(track.cum[n], 1),
                'device_street': f['street'], 'highway': f['highway'],
                'reference_road': f['road_limit'],
                'segment_value': g['seg_kmh'], 'segment_street': g['seg_street'],
                'expected_limit': r['limit'], 'expected_source': r['source'],
                'app_limit': a['limit'], 'app_source': a['source'],
                'app_sign': a['sign'], 'app_sign_road': a['sign_road']})
        fix_out.append({
            'i': n, 't': f['t'], 'tMs': f['tMs'], 'lat': f['lat'],
            'lng': f['lng'], 's_m': round(track.cum[n], 1),
            'speed_kmh': round(f['speed_mps'] * 3.6, 1),
            'street': f['street'], 'highway': f['highway'],
            'road_limit': f['road_limit'],
            'segment_kmh': g['seg_kmh'], 'segment_street': g['seg_street'],
            'segment_dist_m': (None if g['seg_dist'] is None
                               else round(g['seg_dist'], 1)),
            'segment_source': g['source'], 'segment_raw': g['raw'],
            'expected_limit': r['limit'], 'expected_source': r['source'],
            'sign_ahead_m': round(r['expected_sign_ahead'], 1),
            'sign_reason': r['sign_reason'],
            'app_limit': a['limit'], 'app_source': a['source'],
            'app_sign': a['sign'],
            'app_fixed_limit': fixed_rows[n]['limit'],
            'app_fixed_source': fixed_rows[n]['source'],
            'logged_effective': f['old_effective'],
            'logged_announcements': f['announcements'],
        })

    def _diff(other):
        return [n for n, r in enumerate(rows) if r['limit'] != other[n]['limit']]

    return {
        'trip': os.path.basename(trip_path),
        'generatedAt': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'generator': 'tool/trip_truth.py',
        'km': round(total_m / 1000, 3),
        'fix_count': len(fixes),
        'ground_truth': {
            'layer': segments_path,
            'rule': 'nearest waze segment within 25 m, fwd/rev by the recorded '
                    'heading, then effectiveLimit(highway, vehicle, tagged) — '
                    'the same call the app makes in _correctSpeedFromWaze',
            'fallback': 'waze/vietmap point layers within 25 m, then the '
                        'reference run\'s logged speedLimit (source log-road)',
            'sign_policy': 'a sign index point is never authority over the '
                           'segment layer; it is recorded with the reason it '
                           'was ignored',
            'vehicle': vehicle,
        },
        'validation': {
            'fixes': len(fixes),
            'segment_hits': seg_hit,
            'matches_reference_logged_limit': same_all,
            'matches_reference_logged_limit_share': round(
                same_all / max(1, len(fixes)), 4),
            'app_vs_ground_truth_diff': len(_diff(app_rows)),
            'app_fixed_vs_ground_truth_diff': len(_diff(fixed_rows)),
        },
        'datasets': {
            'sign_index': signs_path,
            'segments': os.path.basename(segments_path),
            'segment_count': segs.n_segs,
            'speed_signs': len([s for s in signs
                                if s['kind'] == 'speed' and s['value']]),
        },
        'signs': {
            'speed_on_track': [{'lat': s['lat'], 'lng': s['lng'],
                                'value': s['value'], 's_m': round(s['along'], 1),
                                'off_m': round(s['off'], 1),
                                'seg_street': s['seg_street'],
                                'seg_kmh': s['seg_kmh']}
                               for s in used_signs],
        },
        'limit_events': events,
        'sign_conflicts': sign_notes,
        'divergence': diverge,
        'fixes': fix_out,
    }


def report(truth: dict, inventory: bool):
    fixes = truth['fixes']
    n = len(fixes)
    v = truth['validation']
    print(f'\n--- ground-truth sources ({n} fixes) ---')
    for src, c in Counter(f['expected_source'] for f in fixes).most_common():
        print(f'  {src:<10} {c:>5} ({100.0 * c / n:.0f}%)')
    print(f'\n--- expected limits ---')
    for lim, c in Counter(f['expected_limit'] for f in fixes).most_common():
        print(f'  {lim:>3} km/h  {c:>5} fixes ({100.0 * c / n:.0f}%)')
    print(f'\n--- {len(truth["limit_events"])} expected limit announcements ---')
    for e in truth['limit_events']:
        print(f'  fix {e["i"]:>4} @{e["s_m"]:>7.0f} m  {e["limit"]:>3} km/h '
              f'({e["source"]})  "{e["text"]}"')

    div = truth['divergence']
    v = truth['validation']
    print(f'\n--- rule simulation vs ground truth ---')
    print(f'  app TODAY (sign applies up to 400 m early, road frozen at '
          f'adoption)   : {v["app_vs_ground_truth_diff"]}/{n} fixes differ')
    print(f'  app with the FIX (sign must be REACHED + same road, road bound '
          f'when known): {v["app_fixed_vs_ground_truth_diff"]}/{n} fixes '
          f'differ')
    print(f'\n--- app vs ground truth: {len(div)} of {n} fixes differ '
          f'({100.0 * len(div) / n:.0f}%) ---')
    rem = {}
    for f in fixes:
        if f['expected_limit'] != f['app_fixed_limit']:
            rem.setdefault((f['expected_limit'], f['expected_source'],
                            f['app_fixed_limit'], f['app_fixed_source'],
                            f['segment_source']), []).append(f)
    if rem:
        print(f'\n--- what still differs WITH the fix ({len(rem)} groups) ---')
        for (want, wsrc, got, gsrc, ssrc), rs in sorted(
                rem.items(), key=lambda kv: -len(kv[1]))[:8]:
            span = (f'{min(r["s_m"] for r in rs):.0f}-'
                    f'{max(r["s_m"] for r in rs):.0f} m')
            print(f'  {len(rs):>4} fixes ({span}): expected {want} ({wsrc}) vs '
                  f'fixed app {got} ({gsrc}) — ground-truth source={ssrc}')
    groups = {}
    for d in div:
        groups.setdefault((d['expected_limit'], d['expected_source'],
                           d['app_limit'], d['app_source']), []).append(d)
    for (want, wsrc, got, gsrc), rs in sorted(groups.items(),
                                              key=lambda kv: -len(kv[1])):
        span = f'{min(r["s_m"] for r in rs):.0f}-{max(r["s_m"] for r in rs):.0f} m'
        g = rs[0]
        print(f'  {len(rs):>4} fixes ({span}): app {got} km/h ({gsrc}) vs '
              f'ground truth {want} ({wsrc}) — sign={g["app_sign"]} '
              f'applied on road={g["app_sign_road"]!r}, '
              f'segment_street={g["segment_street"]!r}')

    if truth['sign_conflicts']:
        print(f'\n--- signs sitting ON the car\'s own segment that disagree with '
              f'it ({len(truth["sign_conflicts"])}) ---')
        for c in truth['sign_conflicts'][:12]:
            print(f'  fix {c["i"]:>4} @{c["s_m"]:>6.0f} m segment={c["segment"]} '
                  f'sign={c["sign"]} → capped {c["sign_capped"]} '
                  f'({c["verdict"]}) street={c["street"]}')

    if inventory:
        print('\n--- speed signs on the track ---')
        for s in truth['signs']['speed_on_track']:
            print(f'  @{s["s_m"]:>7.0f} m  sign={s["value"]:>3} km/h  '
                  f'segment_under_it={s["seg_kmh"]} '
                  f'street={s["seg_street"]!r}')
        if not truth['signs']['speed_on_track']:
            print('  (none)')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip')
    ap.add_argument('--vehicle', default='motorbike',
                    choices=['car', 'motorbike', 'truck'])
    ap.add_argument('--signs', default='assets/offline_map/vietnam_signs.json')
    ap.add_argument('--segments', default='assets/offline_map/waze_segments.bin')
    ap.add_argument('--waze-points',
                    default='assets/offline_map/waze_speed_limits.json')
    ap.add_argument('--vietmap-points',
                    default='assets/offline_map/vietmap_speed_limits.json')
    ap.add_argument('--out-dir', default='docs')
    ap.add_argument('--inventory', action='store_true')
    ap.add_argument('--json-only', action='store_true')
    ap.add_argument('--no-write', action='store_true')
    args = ap.parse_args()

    truth = build(args.trip, args.signs, args.vehicle,
                  args.segments, args.waze_points, args.vietmap_points)
    report(truth, args.inventory)
    if args.no_write:
        return 0

    stem = os.path.splitext(os.path.basename(args.trip))[0]
    json_path = os.path.join(args.out_dir, f'trip_truth_{stem}.json')
    with open(json_path, 'w', encoding='utf-8') as fh:
        json.dump(truth, fh, ensure_ascii=False, separators=(',', ':'))
    if not args.json_only:
        js_path = os.path.join(args.out_dir, f'trip_truth_{stem}.js')
        with open(js_path, 'w', encoding='utf-8') as fh:
            fh.write('window.TRUTH_DATA = ')
            json.dump(truth, fh, ensure_ascii=False, separators=(',', ':'))
            fh.write(';\n')
        print(f'wrote {js_path}')
    print(f'wrote {json_path} ({os.path.getsize(json_path) / 1024:.0f} KB)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
