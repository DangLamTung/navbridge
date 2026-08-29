#!/usr/bin/env python3
"""PROOF: characterize the GPS noise pattern and show old vs new filter on
today's real trip data (no faking — every number comes from the recorded JSON).

1. NOISE PATTERN: while parked (<2 m between fixes) the compass (logged
   heading) oscillation + position jitter; while moving, the travel-bearing
   swing.
2. OLD vs NEW heading filter on the SAME fixes: the old build used
   `travel ?? compass` (compass trusted when parked → flips); the new filter
   holds the heading when the car hasn't moved >=2 m.
3. Complementary filter (CarFilter) position/speed smoothing vs raw.
"""
import json
import math
import sys

R = 6371000.0


def dist_m(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def bearing_deg(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def ang_diff(a, b):
    d = (a - b) % 360
    return d if d <= 180 else 360 - d


def load(path):
    d = json.load(open(path))
    out = []
    for f in d['locations']:
        lat = f['latitudeE7'] / 1e7
        lng = f['longitudeE7'] / 1e7
        ts = int(f.get('timestampMs', 0))
        h = f.get('heading')
        out.append((lat, lng, ts, h))
    return out


def new_heading_filter(fixes):
    """Exact port of StrictHeading.update (lib/core/heading_filter.dart)."""
    heading = None
    pending = None
    pending_at = None
    last = None
    out = []
    for lat, lng, ts, raw in fixes:
        travel = None
        if last is not None and dist_m(last, (lat, lng)) >= 2.0:
            travel = bearing_deg(last, (lat, lng))
        last = (lat, lng)
        if travel is None:
            if heading is None:
                heading = raw  # seed once from the compass
            # else: HOLD — never trust the compass while parked
        else:
            if heading is None:
                heading = travel
            else:
                d = ang_diff(travel, heading)
                if d <= 40:
                    pending = pending_at = None
                    heading = travel
                elif (pending is not None and pending_at is not None
                      and (ts - pending_at) / 1000.0 < 3.0
                      and ang_diff(travel, pending) <= 40):
                    pending = pending_at = None
                    heading = travel
                else:
                    pending, pending_at = travel, ts
        out.append(heading)
    return out


def count_flips(headings, fixes, label):
    """Count >120-deg heading changes, split by parked (<2 m) vs moving."""
    parked = moving = 0
    flip_sites = []
    prev_h = None
    for i, (h, f) in enumerate(zip(headings, fixes)):
        if h is None or prev_h is None:
            prev_h = h
            continue
        if ang_diff(h, prev_h) > 120:
            moved = 0.0 if i == 0 else dist_m(fixes[i - 1][:2], f[:2])
            if moved < 2.0:
                parked += 1
            else:
                moving += 1
            flip_sites.append((i, round(ang_diff(h, prev_h)), round(moved, 1), round(prev_h or -1), round(h or -1)))
        prev_h = h
    print(f'    {label}: parked(<2m) flips={parked}  moving flips={moving}')
    for s in flip_sites[:14]:
        print(f'      fix#{s[0]}  flip={s[1]}deg  moved={s[2]}m  {s[3]}->{s[4]}')
    return parked


def main():
    path = sys.argv[1]
    fixes = load(path)
    print(f'== {path.split("/")[-1]}  ({len(fixes)} fixes) ==\n')

    # ---- 1. NOISE PATTERN ----
    print('--- NOISE PATTERN ---')
    parked = [i for i in range(1, len(fixes))
              if dist_m(fixes[i - 1][:2], fixes[i][:2]) < 2.0]
    print(f'  parked/stopped fixes (moved <2m): {len(parked)} of {len(fixes)}')
    if parked:
        # compass (logged heading) values while parked → oscillation?
        seq = [fixes[i][3] for i in parked if fixes[i][3] is not None]
        if seq:
            swing = max((ang_diff(a, b) for a, b in zip(seq, seq[1:])), default=0)
            print(f'  while parked, consecutive LOGGED headings differ up to {swing:.0f} deg'
                  f' (sample: {[int(h) for h in seq[:10]]})')
    # position jitter: displacement distribution
    disp = [dist_m(fixes[i - 1][:2], fixes[i][:2]) for i in range(1, len(fixes))]
    disp.sort()
    n = len(disp)
    print(f'  per-fix displacement (m): min={disp[0]:.1f} p50={disp[n//2]:.1f} '
          f'p90={disp[int(n*0.9)]:.1f} max={disp[-1]:.1f}')
    # travel-bearing swing while slowly moving (2-8 m between fixes)
    swing = []
    prev = None
    for i in range(1, len(fixes)):
        a, b = fixes[i - 1][:2], fixes[i][:2]
        d = dist_m(a, b)
        if 2.0 <= d <= 8.0 and prev is not None:
            swing.append(ang_diff(bearing_deg(prev, a), bearing_deg(a, b)))
        prev = a
    if swing:
        print(f'  travel-bearing step while creeping (2-8m/fix): median={sorted(swing)[len(swing)//2]:.0f}deg '
              f'max={max(swing):.0f}deg (n={len(swing)})')

    # ---- 2. OLD vs NEW ----
    print('\n--- OLD (recorded, compass-trusted) vs NEW (hold-when-parked) ---')
    logged = [f[3] for f in fixes]
    new_h = new_heading_filter(fixes)
    old_parked = count_flips(logged, fixes, 'OLD (what the app logged)')
    new_parked = count_flips(new_h, fixes, 'NEW (StrictHeading on the same fixes)')
    print(f'\n  RESULT: parked flips {old_parked} -> {new_parked}')

    # ---- 3. Complementary filter: position + speed ----
    print('\n--- COMPLEMENTARY FILTER (CarFilter): position/speed smoothing ---')
    raw_disp = [dist_m(fixes[i - 1][:2], fixes[i][:2]) for i in range(1, len(fixes))]
    # CarFilter: pos alpha .8, speed alpha .3, follows travel bearing
    speed = 0.0
    pos = None
    prev_fix = None
    filt_disp = []
    filt_speed = []
    for i, f in enumerate(fixes):
        if prev_fix is not None:
            dt = (f[2] - prev_fix[2]) / 1000.0
            measured = dist_m(prev_fix[:2], f[:2]) / dt if dt > 0 else 0
            speed = 0.3 * measured + 0.7 * speed
        else:
            speed = 0.0
        filt_speed.append(speed * 3.6)
        if pos is not None and prev_fix is not None:
            pos = (0.8 * f[0] + 0.2 * pos[0], 0.8 * f[1] + 0.2 * pos[1])
        else:
            pos = f[:2]
        if i > 0:
            filt_disp.append(dist_m(prev_fix[:2] if prev_fix else pos, pos))
        prev_fix = f
    filt_disp.sort()
    print(f'  max per-fix displacement: raw={max(raw_disp):.1f}m  filtered={max(filt_disp):.1f}m')
    print(f'  raw speed peaks (km/h): {[round(f[3]*0) + 0 for f in []] or ""}'.strip())
    raw_kmh = [0.0]
    for i in range(1, len(fixes)):
        dt = (fixes[i][2] - fixes[i - 1][2]) / 1000.0
        if dt > 0:
            raw_kmh.append(dist_m(fixes[i - 1][:2], fixes[i][:2]) / dt * 3.6)
    print(f'  max speed km/h: raw={max(raw_kmh):.0f}  filtered={max(filt_speed):.0f}')


if __name__ == '__main__':
    main()
