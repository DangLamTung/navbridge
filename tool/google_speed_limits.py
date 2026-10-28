#!/usr/bin/env python3
"""Ask Google's Roads API for the posted speed limit at N places in Vietnam.

Answers one question: can Google be used as a speed-limit source here? It calls
the real endpoint, so the answer is evidence, not documentation.

    snapToRoads     -> the road segment's placeId (works in VN)
    speedLimits     -> the posted limit for that segment (see below)

Reads the key from `.env` (GOOGLEMAPS_API_KEY) and never prints it.

Result measured 2026-10-28 with this project's key:
  snapToRoads  20/20 OK  -> roads and placeIds resolve fine in VN
  speedLimits   0/20     -> HTTP 403 "Speed limits are not available for this
                            project."
and Google's own coverage table lists `Speed Limits: —` for VN (available for
Geocoding / Traffic / Snap to Roads, not for Speed Limits). So the limit data
does not exist for Vietnam; this is not a key or billing mistake.

Usage
    python3 tool/google_speed_limits.py                 # 20 places on the 2026-10-25 drive
    python3 tool/google_speed_limits.py --points 50
    python3 tool/google_speed_limits.py --gps build/web/trips/sim_2510.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M_PER_DEG_LAT = 111320.0


def key_from_env() -> str:
    env = {}
    with open(os.path.join(ROOT, '.env')) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    key = env.get('GOOGLE_PLACES_KEY') or env.get('GOOGLEMAPS_API_KEY')
    if not key:
        raise SystemExit('no Google key in .env')
    return key


def http_get(url: str) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(url, timeout=25) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def km_marks(pts, n):
    """`n` points spread evenly by distance along the drive."""
    cum = [0.0]
    for i in range(1, len(pts)):
        dy = (pts[i][0] - pts[i - 1][0]) * M_PER_DEG_LAT
        dx = ((pts[i][1] - pts[i - 1][1]) * M_PER_DEG_LAT
              * math.cos(math.radians(pts[i][0])))
        cum.append(cum[-1] + math.hypot(dx, dy))
    total = cum[-1]
    out = []
    for k in range(n):
        want = total * (k + 0.5) / n
        i = min(range(len(cum)), key=lambda j: abs(cum[j] - want))
        out.append((cum[i] / 1000.0, pts[i]))
    return out, total / 1000.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gps', default=os.path.join(ROOT, 'build/web/trips/sim_2510.json'))
    ap.add_argument('--points', type=int, default=20)
    ap.add_argument('--waze', default=os.path.join(ROOT, 'assets/offline_map/waze_segments.bin'))
    args = ap.parse_args()

    key = key_from_env()
    locs = json.load(open(args.gps))['locations']
    pts = [(l['latitudeE7'] / 1e7, l['longitudeE7'] / 1e7) for l in locs]
    picks, total_km = km_marks(pts, args.points)

    sys.path.insert(0, os.path.join(ROOT, 'tool'))
    from waze_segments import Segments
    seg = Segments(args.waze)

    print(f'{args.points} điểm trên tuyến {total_km:.0f} km\n')
    print('  km    toạ độ                snap  Google   Waze  kết quả')
    print('  ----- ---------------------- ----- -------- ----- ------------------------')
    snap_ok = lim_ok = 0
    agree = 0
    for km, (lat, lng) in picks:
        # 1. a road segment placeId for this position
        st, body = http_get(
            'https://roads.googleapis.com/v1/snapToRoads'
            f'?path={lat:.6f},{lng:.6f}|{lat + 0.0001:.6f},{lng:.6f}'
            f'&interpolate=false&key={key}')
        place = None
        if st == 200:
            sp = json.loads(body).get('snappedPoints') or []
            place = sp[0].get('placeId') if sp else None
            snap_ok += bool(place)
        # 2. the posted limit for that segment
        gl, note = None, ''
        if place:
            st2, body2 = http_get(
                'https://roads.googleapis.com/v1/speedLimits'
                f'?placeId={urllib.parse.quote(place)}&units=KPH&key={key}')
            if st2 == 200:
                sl = json.loads(body2).get('speedLimits') or []
                gl = sl[0].get('speedLimit') if sl else None
                note = '' if gl else 'no speedLimit in response'
            else:
                try:
                    note = json.loads(body2)['error']['message']
                except Exception:
                    note = body2[:60]
        else:
            note = 'snap failed'
        if gl:
            lim_ok += 1
        wz = seg.query(lat, lng)[0]
        gtxt = f'{gl:>3d}   ' if gl else '  -   '
        print(f'  {km:5.1f} {lat:.6f},{lng:.6f} {"OK " if place else "X  "} '
              f'{gtxt} {wz:>4d}  {note}')
        if gl and wz and gl == wz:
            agree += 1

    print(f'\nsnapToRoads: {snap_ok}/{len(picks)} | speedLimits: {lim_ok}/{len(picks)}'
          f' | trùng Waze: {agree}/{lim_ok or 1}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
