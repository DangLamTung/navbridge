#!/usr/bin/env python3
"""Emit before/after speed + location series for a trip (JSON, one array/line).

Before  = raw GPS (position-derived implied speed, per-fix jump)
After   = CarFilter (complementary filter: speed EMA a=0.3, pos fusion a=0.8)
           + route snap + OutlierGate (rejected bursts show as 0 on 'after'
           axes, red flag list).
"""
import json
import math
import sys

R = 6371000.0


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def dm_flat(a, b):
    md = 111320.0
    ml = md * math.cos(a[0] * math.pi / 180)
    dLa = (b[0] - a[0]) * md
    dLo = (b[1] - a[1]) * ml
    return math.sqrt(dLa * dLa + dLo * dLo)


def gate(prev, pos, dt, smooth):
    if prev is None or dt is None or dt <= 0:
        return True, smooth
    d = dm_flat(prev, pos)
    allowed = max(smooth, 5.0) * dt * 3.0
    if d > allowed:
        return False, smooth
    smooth = 0.5 * (d / dt) + 0.5 * smooth
    return True, smooth


def main():
    path = sys.argv[1]
    d = json.load(open(path))
    fixes = [(f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7, int(f['timestampMs'])) for f in d['locations']]

    speed_raw, speed_filt, jump_raw, jump_filt, rej = [], [], [], [], []
    car_spd = 0.0
    car_pos = None
    prev_filt = None     # previous FILTERED position (for filtered jump)
    g_smooth = 0.0
    last = None          # last accepted fix (lat,lng,ts) for the gate
    last_raw = None      # previous raw fix for raw implied speed/jump
    for i, (lat, lng, ts) in enumerate(fixes):
        pos = (lat, lng)
        # --- OutlierGate (dt since last ACCEPTED) ---
        dt_g = None if last is None else (ts - last[2]) / 1000.0
        prev_g = None if last is None else last[:2]
        ok, g_smooth = gate(prev_g, pos, dt_g, g_smooth)
        if ok:
            last = (lat, lng, ts)

        # --- raw implied speed + jump + CarFilter (fed raw fixes) ---
        dt_r = 0.0
        dm = 0.0
        if last_raw is not None:
            dt_r = (ts - last_raw[2]) / 1000.0
            dm = dist(last_raw[:2], pos)
            if dt_r > 0:
                car_spd = 0.3 * (dm / dt_r) + 0.7 * car_spd
            if car_pos is not None and 0 < dt_r < 1.0 and car_spd > 0.3:
                car_pos = (0.8 * lat + 0.2 * car_pos[0], 0.8 * lng + 0.2 * car_pos[1])
            else:
                car_pos = pos
        else:
            car_pos = pos
        last_raw = (lat, lng, ts)

        speed_raw.append(round(dm / dt_r * 3.6, 1) if dt_r > 0 else 0.0)
        speed_filt.append(round(car_spd * 3.6, 1))
        jump_raw.append(round(dm, 1))
        jump_filt.append(round(dist(prev_filt, car_pos), 1) if prev_filt is not None else 0.0)
        prev_filt = car_pos
        rej.append(1 if not ok else 0)

    out = {
        'fixes': len(fixes),
        'speed_raw_kmh': speed_raw,
        'speed_filt_kmh': speed_filt,
        'jump_raw_m': jump_raw,
        'jump_filt_m': jump_filt,
        'rejected': rej,
    }
    # print compact one-line JSON for each array
    for k, v in out.items():
        if isinstance(v, list):
            print(f'{k} = [{",".join(map(str, v))}]')
        else:
            print(f'{k} = {v}')


if __name__ == '__main__':
    main()
