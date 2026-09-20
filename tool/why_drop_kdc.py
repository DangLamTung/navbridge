#!/usr/bin/env python3
"""Measure WHY the khu-đông-dân-cư (built-up boundary) sign layer was dropped.

Three independent checks, all against data already in the repo — no assertion
without a number:

  1. WHERE the points are. A "bắt đầu khu đông dân cư" point inside a city is a
     contradiction by definition; count how many sit in the HCMC / Hà Nội bbox,
     and how densely they repeat along the same streets.

  2. WHAT they would do. At each boundary point, query the Waze/WME segment
     layer UNDER the point and compare it with the built-up cap the app applied
     (urbanLimit). Every point where the layer posts MORE than the cap is a
     point where the boundary would have LOWERED a real posted limit.

  3. WHAT they did. Replay the OLD rule (cap in force while a boundary is within
     400 m ahead) over every recorded drive and count the fixes where the cap
     contradicts the segment layer under the car — i.e. how many fix-seconds of
     real driving were spent at a limit the posted-limit layer disagrees with.

Usage: python3 tool/why_drop_kdc.py [--trips docs/trips/device]
"""
from __future__ import annotations

import argparse
import bisect
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

ASSET = 'assets/offline_map/vietnam_signs.json'
SEGS = 'assets/offline_map/waze_segments.bin'
VEHICLE = 'motorbike'
BOUNDARY = ('populated', 'populated_end')

# Rough city bounding boxes — a built-up boundary point inside one of these is
# the point being in a built-up area, which is what the sign is supposed to say.
CITIES = {
    'TP.HCM': (10.55, 106.35, 11.10, 107.05),
    'Hà Nội': (20.75, 105.55, 21.25, 106.05),
    'Đà Nẵng': (15.90, 107.95, 16.15, 108.30),
}


def in_city(lat, lng):
    for name, (a, b, c, d) in CITIES.items():
        if a <= lat <= c and b <= lng <= d:
            return name
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--trips', default='docs/trips/device')
    ap.add_argument('--max-points', type=int, default=0,
                    help='0 = every boundary point')
    args = ap.parse_args()

    with open(ASSET, encoding='utf-8') as fh:
        rows = json.load(fh)['signs']
    bounds = [r for r in rows if r.get('kind') in BOUNDARY]
    starts = [r for r in bounds if r['kind'] == 'populated']
    ends = [r for r in bounds if r['kind'] == 'populated_end']
    print(f'sign asset                      : {len(rows)} rows')
    print(f'  built-up boundary rows        : {len(bounds)} '
          f'({100.0 * len(bounds) / len(rows):.1f}% of the whole DB)')
    print(f'    "bắt đầu" {len(starts)}  /  "hết" {len(ends)}')

    # --- 1. where they are -------------------------------------------------
    city_count = collections.Counter()
    for r in bounds:
        c = in_city(r['lat'], r['lng'])
        if c:
            city_count[c] += 1
    print('\n--- 1. a boundary INSIDE a city is self-contradictory ---')
    for c, n in city_count.most_common():
        print(f'  inside {c:<8}: {n:>5} boundary points')
    hcmc = [r for r in bounds if in_city(r['lat'], r['lng']) == 'TP.HCM']
    # Density: how close is the next boundary point along the same street?
    if hcmc:
        grid = collections.defaultdict(list)
        for r in hcmc:
            grid[(round(r['lat'], 3), round(r['lng'], 3))].append(r)
        gaps = []
        for r in hcmc[:4000]:
            best = None
            for dlat in (-0.01, 0, 0.01):
                for dlng in (-0.01, 0, 0.01):
                    for o in grid.get((round(r['lat'] + dlat, 3),
                                       round(r['lng'] + dlng, 3)), ()):
                        if o is r:
                            continue
                        d = T.meters((r['lat'], r['lng']), (o['lat'], o['lng']))
                        if d > 1 and (best is None or d < best):
                            best = d
            if best is not None:
                gaps.append(best)
        gaps.sort()
        if gaps:
            q = lambda p: gaps[int(p * (len(gaps) - 1))]  # noqa: E731
            print(f'  TP.HCM spacing between neighbouring boundary points: '
                  f'median {q(0.5):.0f} m, 10th pct {q(0.1):.0f} m, '
                  f'{sum(1 for g in gaps if g < 100)} of {len(gaps)} closer '
                  f'than 100 m')

    # --- 2. what they would do (vs the posted-limit layer) ------------------
    segs = T.Segments(SEGS)
    sample = bounds if not args.max_points else bounds[:args.max_points]
    on_seg = over50 = over60 = 0
    street_hits = collections.Counter()
    for r in sample:
        kmh, street, cls, sep, dist, sid = segs.query(r['lat'], r['lng'])
        if not kmh:
            continue
        on_seg += 1
        if kmh > 50:
            over50 += 1
            street_hits[street or '?'] += 1
        if kmh > 60:
            over60 += 1
    print('\n--- 2. what the cap would have done to the posted limit ---')
    if on_seg:
        print(f'  boundary points sitting on a Waze segment : {on_seg}/{len(sample)}')
        print(f'    segment posts > 50 km/h (cap would LOWER it): '
              f'{over50} ({100.0 * over50 / on_seg:.0f}%)')
        print(f'    segment posts > 60 km/h (even the divided cap): {over60}')
        print('    top streets where the boundary fights the posted limit:')
        for s, n in street_hits.most_common(6):
            print(f'      {n:>4}  {s}')

    # --- 3. what they did on real drives -----------------------------------
    files = sorted(f for f in glob.glob(os.path.join(args.trips, '*.json'))
                   if 'emulator' not in os.path.basename(f))
    pt_index = T.PointIndex(T.load_speed_points(
        'assets/offline_map/waze_speed_limits.json',
        'assets/offline_map/vietmap_speed_limits.json'))
    print(f'\n--- 3. replaying the OLD rule over {len(files)} recorded drives ---')
    tot = collections.Counter()
    per_trip = []
    for path in files:
        _meta, fixes = T.load_trip(path)
        if not fixes:
            continue
        track = T.Track([(f['lat'], f['lng']) for f in fixes])
        on_track = []
        for b in bounds:
            pr = track.project(b['lat'], b['lng'])
            if pr is not None:
                on_track.append({'along': pr[0], 'kind': b['kind']})
        if not on_track:
            continue
        on_track.sort(key=lambda b: b['along'])
        alongs = [b['along'] for b in on_track]
        gt_rows = T.ground_truth(fixes, segs, pt_index, VEHICLE)

        # The old rule: the cap is in force while a boundary point is within
        # ADOPT_M ahead on the route, exactly as nav_signs.dart did it.
        in_zone, lowered, overrode, enters = False, 0, 0, 0
        for i, fx in enumerate(fixes):
            s = track.cum[i]
            k = bisect.bisect_left(alongs, s)
            if k < len(on_track) and on_track[k]['along'] - s <= T.ADOPT_M:
                b = on_track[k]
                if b['kind'] == 'populated' and not in_zone:
                    in_zone, enters = True, enters + 1
                elif b['kind'] == 'populated_end' and in_zone:
                    in_zone = False
            gt = gt_rows[i]
            if not in_zone or not gt['limit']:
                continue
            cap = T.urban_limit(VEHICLE, bool(gt['seg_sep']))
            if cap >= gt['limit']:
                continue
            lowered += 1
            # Did it overrule real evidence, or fill a gap? A segment-layer
            # value is evidence; the reference log's own value is not.
            if gt['source'] == 'segment' and (gt['raw'] or 0) > cap:
                overrode += 1
        if lowered:
            per_trip.append((os.path.basename(path), len(fixes), enters,
                             lowered, overrode))
            tot['fixes'] += len(fixes)
            tot['lowered'] += lowered
            tot['overrode'] += overrode
            tot['enters'] += enters
    print(f'  drives where the boundary changed the limit : {len(per_trip)}')
    print(f'  boundary crossings (enter)                  : {tot["enters"]}')
    print(f'  fixes where the cap lowered the limit       : {tot["lowered"]}')
    print(f'    of those, the cap OVERRODE a segment-layer posted value: '
          f'{tot["overrode"]}')
    print('\n  worst drives (fixes, enters, lowered, overrode a posted value):')
    for name, n, e, low, ov in sorted(per_trip, key=lambda r: -r[3])[:8]:
        print(f'    {name:<48} {n:>5} fixes  {e:>3} enter  '
              f'{low:>4} lowered  {ov:>4} overrode')
    if not per_trip:
        print('    (none — the boundary layer never fired on any recorded drive)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
