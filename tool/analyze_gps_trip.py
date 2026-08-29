#!/usr/bin/env python3
"""Analyze a recorded trip log for GPS anomalies (jumps, 180 flips, accuracy)."""
import json
import math
import sys

path = sys.argv[1] if len(sys.argv) > 1 else '2026-08-08_200603_Chuyến_đi.json'
d = json.load(open(path))
locs = d.get('locations', [])
print(f'file={path} fixes={len(locs)}')

prev = None
jumps = []
flips = []
slow_flips = []
acc_high = []
total_m = 0.0
speeds = []


def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


for i, f in enumerate(locs):
    lat = f['latitudeE7'] / 1e7
    lng = f['longitudeE7'] / 1e7
    acc = f.get('accuracy', 0)
    src = f.get('source', '?')
    t = int(f.get('timestampMs', 0))
    if acc > 25:
        acc_high.append((i, acc, lat, lng))
    if prev is None:
        prev = (lat, lng, t, None)
        continue
    pl, pn, pt, pb = prev
    dt = (t - pt) / 1000.0
    dm = dist((pl, pn), (lat, lng))
    total_m += dm
    spd = dm / dt if dt > 0 else 0
    speeds.append(spd)
    b = bearing((pl, pn), (lat, lng))
    if pb is not None and dm > 1.0:
        bd = abs((b - pb + 540) % 360 - 180)
        if bd > 120:
            if spd > 6:
                flips.append((i, bd, spd, dm, acc))
            else:
                slow_flips.append((i, bd, spd, dm, acc))
    if spd > 40:
        jumps.append((i, spd, dm, dt, acc))
    prev = (lat, lng, t, b)

moving = [s for s in speeds if s > 1.0]
print(f'distance={total_m:.0f} m  peak_speed={max(speeds):.1f} m/s ({max(speeds)*3.6:.0f} km/h)')
print(f'moving-avg speed={sum(moving)/len(moving)*3.6:.0f} km/h (n={len(moving)})')
print(f'\nJUMPS (spd>40 m/s = 144 km/h): {len(jumps)}')
for j in jumps[:15]:
    print(f'  fix#{j[0]} spd={j[1]*3.6:.0f} km/h jump={j[2]:.0f} m dt={j[3]:.1f}s acc={j[4]}m')
print(f'\nHEADING FLIPS while moving (>120 deg, spd>6 m/s): {len(flips)}')
for f in flips[:20]:
    print(f'  fix#{f[0]} flip={f[1]:.0f} deg spd={f[2]*3.6:.0f} km/h moved={f[3]:.0f} m acc={f[4]}m')
print(f'\nslow flips (spd<=6): {len(slow_flips)} (first 8)')
for f in slow_flips[:8]:
    print(f'  fix#{f[0]} flip={f[1]:.0f} deg spd={f[2]*3.6:.0f} km/h moved={f[3]:.0f} m')
print(f'\naccuracy>25m: {len(acc_high)} (first 8)')
for a in acc_high[:8]:
    print(f'  fix#{a[0]} acc={a[1]}m @ {a[2]:.6f},{a[3]:.6f}')

# New: analyze the LOGGED heading field (the arrow heading the app showed).
headings = [f.get('heading') for f in locs]
if any(h is not None for h in headings):
    h_flips = []
    h_changes = []
    prev_h = None
    for i, h in enumerate(headings):
        if h is None:
            prev_h = None
            continue
        if prev_h is not None:
            hd = abs((h - prev_h + 540) % 360 - 180)
            h_changes.append((i, hd, h, prev_h))
            if hd > 120:
                h_flips.append((i, hd, h, prev_h))
        prev_h = h
    print(f'\nLOGGED-heading flips (>120 deg between logged fixes): {len(h_flips)}')
    for f in h_flips[:25]:
        print(f'  fix#{f[0]} flip={f[1]:.0f} deg  h={f[2]} -> prev={f[3]}')
else:
    print('\nLOGGED heading: (none recorded in this log)')
