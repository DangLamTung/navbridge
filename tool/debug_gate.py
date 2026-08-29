#!/usr/bin/env python3
"""Debug the OutlierGate on a real trip (replicate the Dart logic)."""
import json
import math
import sys

R = 6371000.0


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def main():
    path = sys.argv[1]
    d = json.load(open(path))
    fixes = [(f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7, int(f['timestampMs'])) for f in d['locations']]
    floor = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    factor = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0

    smooth = 0.0
    last = None
    rej = 0
    acc = 0
    first = min(40, len(fixes))
    print(f'floor={floor} factor={factor}  (gate: allowed = max(smooth,floor)*dt*factor)')
    print(' i   dt     d    implied  smooth  allowed  ->')
    for i, (lat, lng, ts) in enumerate(fixes):
        pos = (lat, lng)
        dt = None if last is None else (ts - last[2]) / 1000.0
        prev = None if last is None else last[:2]
        if prev is not None and dt is not None and dt > 0:
            dm = dist(prev, pos)
            implied = dm / dt
            allowed = max(smooth, floor) * dt * factor
            if dm > allowed:
                if i < first:
                    print(f'{i:3d} {dt:5.2f} {dm:6.1f} {implied*3.6:5.0f} {smooth:5.1f} {allowed:6.1f}  REJECT')
                rej += 1
                continue
            smooth = 0.5 * implied + 0.5 * smooth
        last = (lat, lng, ts)
        acc += 1
    print(f'total accepted={acc} rejected={rej}')


if __name__ == '__main__':
    main()
