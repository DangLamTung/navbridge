#!/usr/bin/env python3
"""Which SIDE of the driven line does a sign stand on — and does that match the law?

QCVN 41:2019 puts a biển báo hiệu on the RIGHT-hand verge for the traffic it
governs; the same plate on the left belongs to the opposite carriageway. The app
filters signs with `signedLateralOffsetMeters` (positive = right of travel) and
`kLeftSideToleranceM` (a plate within 6 m left of the centreline is not evidence
of a side — most speed rows store the road's own coordinate).

This tool measures both halves of that claim on a recorded drive:

  1. THE DATA — every sign the app loads within `--corridor` of the driven line,
     split by side and kind. Tells you whether left-side plates exist at all and
     how many the filter has to remove.
  2. THE BEHAVIOUR — every sign callout in a simulated trip, matched back to the
     plate that produced it (same kind, nearest ahead), and the side of THAT
     plate. Any LEFT plate in this list is a bug.

Usage
    python3 tool/sign_side_audit.py --gps build/web/trips/sim_2510.json \
        --trip "$TMPDIR/sim_state.json"
    python3 tool/sign_side_audit.py --gps ... --corridor 60 --verbose
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tool'))
from signs_app_filter import load_app_signs  # noqa: E402

M_PER_DEG_LAT = 111320.0
LEFT_TOLERANCE_M = 6.0  # mirror of kLeftSideToleranceM


def m_per_deg_lng(lat):
    return M_PER_DEG_LAT * math.cos(math.radians(lat))


def dist_m(a, b):
    dy = (b[0] - a[0]) * M_PER_DEG_LAT
    dx = (b[1] - a[1]) * m_per_deg_lng((a[0] + b[0]) / 2)
    return math.hypot(dx, dy)


def signed_offset(pts, cum, lat, lng, window_m=200.0):
    """(metres right of travel, km along the drive) or (None, None) if far off."""
    best = (float('inf'), 0.0, 0.0)
    n = len(pts)
    step = max(1, n // 4000)
    ci = min(range(0, n, step), key=lambda i: dist_m(pts[i], (lat, lng)))
    lo, hi = max(0, ci - 40), min(n - 1, ci + 400)
    for i in range(lo, hi):
        ay, ax = pts[i]
        by, bx = pts[i + 1]
        vy, vx = by - ay, bx - ax
        L2 = vy * vy + vx * vx
        if L2 == 0:
            continue
        t = max(0.0, min(1.0, ((lat - ay) * vy + (lng - ax) * vx) / L2))
        py, px = ay + t * vy, ax + t * vx
        d = dist_m((lat, lng), (py, px))
        if d < best[0]:
            # cross product in a local x=east / y=north frame: > 0 ⇒ right
            segX = vx * m_per_deg_lng(ay)
            segY = vy * M_PER_DEG_LAT
            toX = (lng - px) * m_per_deg_lng(ay)
            toY = (lat - py) * M_PER_DEG_LAT
            cross = segY * toX - segX * toY
            along = cum[i] + t * math.hypot(segX, segY)
            best = (d, cross, along)
    d, cross, along = best
    if d > window_m:
        return None, None
    if d < 0.5:
        return 0.0, along / 1000.0
    return (d if cross >= 0 else -d), along / 1000.0


CUE_KIND = {
    'Tốc độ tối đa': 'speed',
    'Cấm vượt': 'no_passing',
    'Hết cấm vượt': 'no_passing_end',
    'Cấm rẽ trái': 'no_left_turn',
    'Cấm rẽ phải': 'no_right_turn',
    'Cấm quay đầu': 'no_uturn',
    'Đường ngang giao với đường sắt': 'railway_crossing',
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gps', required=True)
    ap.add_argument('--trip', default='')
    ap.add_argument('--corridor', type=float, default=60.0)
    ap.add_argument('--log', default='',
                    help='simulation log: read the app\'s OWN dx per callout '
                         '("SIGNS: callout <kind> dx=<m> ahead=<m>")')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    locs = json.load(open(args.gps))['locations']
    pts = [(l['latitudeE7'] / 1e7, l['longitudeE7'] / 1e7) for l in locs]
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + dist_m(pts[i - 1], pts[i]))

    signs, stats = load_app_signs(os.path.join(ROOT, 'assets/offline_map/vietnam_signs.json'))
    near = []
    for r in signs:
        off, km = signed_offset(pts, cum, r['lat'], r['lng'])
        if off is None or abs(off) > args.corridor:
            continue
        near.append((km, off, r))
    near.sort()

    print(f'route {cum[-1]/1000:.1f} km | pack {stats["kept"]} sign(s) the app loads | '
          f'trong corridor {args.corridor:.0f} m: {len(near)}')
    groups = defaultdict(Counter)
    for _km, off, r in near:
        side = 'right' if off >= 0 else ('on-line' if abs(off) < 0.5 else 'LEFT')
        if side != 'LEFT' and off < LEFT_TOLERANCE_M * -1:
            side = 'LEFT'
        groups[r.get('kind')][side] += 1
    print('\n  kind                 right  on-line  LEFT   (LEFT = của chiều ngược lại)')
    for kind, c in sorted(groups.items(), key=lambda kv: -sum(kv[1].values())):
        print(f'  {kind:20s} {c["right"]:6d} {c["on-line"]:8d} {c["LEFT"]:5d}')
    tot = Counter()
    for c in groups.values():
        tot.update(c)
    print(f'  {"TỔNG":20s} {tot["right"]:6d} {tot["on-line"]:8d} {tot["LEFT"]:5d}')

    left_speed = [(km, off, r.get('value')) for km, off, r in near
                  if off < -LEFT_TOLERANCE_M and r.get('kind') == 'speed']
    print(f'\nspeed plate(s) LEFT of the line (filtered out): {len(left_speed)}')
    for km, off, v in left_speed[:10]:
        print(f'    km {km:7.1f}  {off:7.1f} m  {v} km/h')

    if args.log:
        import re
        seen, rows = set(), []
        pat = re.compile(r'SIGNS: callout (\w+) dx=(-?[\d.]+) m ahead=(\d+)')
        for line in open(args.log, encoding='utf-8', errors='replace'):
            mm = pat.search(line)
            if not mm:
                continue
            k = mm.groups()
            if k in seen:
                continue
            seen.add(k)
            rows.append((k[0], float(k[1]), int(k[2])))
        b = Counter()
        for _k, dx, _a in rows:
            if dx < -LEFT_TOLERANCE_M:
                b['TRÁI NGOÀI DUNG SAI (< -6 m)'] += 1
            elif dx < 0:
                b['trái trong dung sai (-6..0 m)'] += 1
            elif dx <= 6:
                b['phải, sát (0..6 m)'] += 1
            else:
                b['phải, xa (> 6 m)'] += 1
        print(f'\n{len(rows)} callout — dx do CHÍNH APP đo trên polyline tuyến:')
        for k, v in b.items():
            print(f'  {k:32s} {v}')
        return 0

    if not args.trip:
        return 0
    trip = json.load(open(args.trip))
    calls = [a for a in trip.get('announcements', [])
             if a.get('kind') == 'sign' and 'khu dân cư' not in a.get('text', '').lower()]
    print(f'\n{len(calls)} sign callout(s) in the trip — plate each one came from:')
    bad = 0
    for a in calls:
        tx = a.get('text', '')
        kind = next((k for cue, k in CUE_KIND.items() if tx.startswith(cue)), None)
        car_off, car_km = signed_offset(pts, cum, a['lat'], a['lng'])
        if car_km is None:
            print(f'  {tx[:44]:46s} (off route)')
            continue
        cand = [(abs(s[0] - car_km), s) for s in near
                if s[2].get('kind') == kind and -0.05 <= s[0] - car_km <= 0.45]
        if not cand:
            print(f'  km {car_km:7.1f} {tx[:44]:46s} no plate of that kind ahead')
            continue
        cand.sort(key=lambda c: c[0])
        s_km, (km, off, r) = cand[0]
        flag = '❌ LEFT' if off < -LEFT_TOLERANCE_M else 'OK'
        if off < -LEFT_TOLERANCE_M:
            bad += 1
        if args.verbose or off < -LEFT_TOLERANCE_M:
            print(f'  km {car_km:7.1f} {tx[:40]:42s} plate {km:7.1f} {off:7.1f} m  {flag}')
    print(f'\ncallouts from a LEFT-hand plate: {bad}/{len(calls)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
