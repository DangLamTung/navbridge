#!/usr/bin/env python3
"""Dump context around heading flips + speed spikes in a trip log."""
import json
import math
import sys


def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


path = sys.argv[1]
focus = [int(x) for x in sys.argv[2].split(',')] if len(sys.argv) > 2 else []
d = json.load(open(path))
locs = d.get('locations', [])
print('file=%s fixes=%d' % (path, len(locs)))
print('%-5s %-10s %-5s %-6s %-6s %-6s %-6s %-6s %s' % (
    'i', 'time', 'acc', 'moved', 'spdkmh', 'trkBrg', 'h_log', 'h_prev', 'flip?'))

prev = None
prev_h = None
last_t = None
for i, f in enumerate(locs):
    lat = f['latitudeE7'] / 1e7
    lng = f['longitudeE7'] / 1e7
    t = int(f.get('timestampMs', 0))
    h = f.get('heading')
    if prev:
        dm = dist((prev[0], prev[1]), (lat, lng))
        dt = (t - last_t) / 1000.0 if last_t else 1.0
        spd = dm / dt if dt > 0 else 0
        brg = bearing((prev[0], prev[1]), (lat, lng))
    else:
        dm = spd = 0.0
        brg = None
    if focus and i not in focus:
        prev = (lat, lng); last_t = t; prev_h = h
        continue
    flip = ''
    if prev_h is not None and h is not None:
        bd = abs((h - prev_h + 540) % 360 - 180)
        if bd > 90:
            flip = '<<< FLIP %.0f' % bd
    show = (not focus) or (i in focus)
    if show:
        print('%-5d %-10s %-5s %-6.1f %-6.1f %-6s %-6s %-6s %s' % (
            i, f.get('time', '')[:10] if f.get('time') else '',
            f.get('accuracy'), dm, spd * 3.6,
            '%.0f' % brg if brg is not None else '-',
            '%.0f' % h if h is not None else '-',
            '%.0f' % prev_h if prev_h is not None else '-', flip))
    prev = (lat, lng); last_t = t; prev_h = h
