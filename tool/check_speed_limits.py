#!/usr/bin/env python3
"""Sanity-check the bundled speed-limit layer: nearest DATMAP segment distance
and limit at major city centers. Mirrors lib/services/offline_speed_limits.dart.
"""
import json
import math
import random
import sys

CELL = 0.02
MPD = 111320.0


def build(path):
    d = json.load(open(path))
    meta, coords, offsets, grid = [], [], [], {}
    for f in d["features"]:
        line = (f.get("geometry") or {}).get("coordinates") or []
        p = f.get("properties") or {}
        fwd = p.get("fwdMaxSpeed", 0) or 0
        rev = p.get("revMaxSpeed", 0) or 0
        # Start of this segment's coords, recorded BEFORE extending (matches
        # the Dart service: offsets[i] is the pair index where segment i
        # begins). No leading sentinel here — the array is empty initially.
        offsets.append(len(coords) // 2)
        if line:
            lons = [c[0] for c in line]
            lats = [c[1] for c in line]
            key = ((int(sum(lons) / len(lons) // CELL) & 0xFFFF) << 16) | (
                int(sum(lats) / len(lats) // CELL) & 0xFFFF
            )
            grid.setdefault(key, []).append(len(meta))
        meta.append(
            (
                fwd,
                rev,
                min(lons) if line else 0,
                max(lons) if line else 0,
                min(lats) if line else 0,
                max(lats) if line else 0,
            )
        )
        coords.extend(x for c in line for x in c)
    offsets.append(len(coords) // 2)  # final sentinel
    return meta, coords, offsets, grid


def seg_dist(meta, coords, offsets, i, lon, lat, cos):
    a, b = offsets[i] * 2, offsets[i + 1] * 2
    if b - a < 4:
        return 1e9
    best = 1e18
    vx, vy = coords[a], coords[a + 1]
    for k in range(a + 2, b, 2):
        qx, qy = coords[k], coords[k + 1]
        axx, bxx, pxx = vx * cos, qx * cos, lon * cos
        dx, dy = bxx - axx, qy - vy
        l2 = dx * dx + dy * dy
        if l2 == 0:
            e, ey = pxx - axx, lat - vy
            d2 = e * e + ey * ey
        else:
            t = max(0.0, min(1.0, ((pxx - axx) * dx + (lat - vy) * dy) / l2))
            cx, cy = axx + t * dx, vy + t * dy
            e, ey = pxx - cx, lat - cy
            d2 = e * e + ey * ey
        best = min(best, d2)
        vx, vy = qx, qy
    return math.sqrt(best) * MPD


def lookup(meta, coords, offsets, grid, lon, lat, maxd=25):
    cos = math.cos(math.radians(lat))
    cx, cy = int(lon // CELL), int(lat // CELL)
    best, bs, bi = 1e18, 0, -1
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            key = (((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF)
            for i in grid.get(key, []):
                f, r, minlon, maxlon, minlat, maxlat = meta[i]
                if (
                    lon < minlon - 0.0003
                    or lon > maxlon + 0.0003
                    or lat < minlat - 0.0003
                    or lat > maxlat + 0.0003
                ):
                    continue
                dist = seg_dist(meta, coords, offsets, i, lon, lat, cos)
                if dist < best:
                    best = dist
                    bs = max(f, r) if f > 0 and r > 0 else (f or r)
                    bi = i
    if best <= maxd and 5 <= bs <= 200:
        return round(bs), round(best), bi
    return None


def self_check(meta, coords, offsets, grid, n=2000):
    """Query at random on-segment points (with a small GPS-ish offset); the
    returned limit must equal the segment's own posted limit (we're on it).

    Classifies outcomes:
      - ok: matched the segment's own limit
      - zero_limit: segment has no limit (fwd=rev=0) and lookup correctly
        returned None — NOT a failure
      - ambiguous: found a different limit, but the found segment is within
        ~10 m (two crossing roads) — inherent to nearest-segment semantics
      - fail: anything else (missed the road entirely, or wrong limit far away)
    """
    rng = random.Random(7)
    segs = [i for i, m in enumerate(meta) if offsets[i + 1] > offsets[i]]
    rng.shuffle(segs)
    ok = zero = amb = fail = 0
    for i in segs[:n]:
        a, b = offsets[i] * 2, offsets[i + 1] * 2
        k = rng.randrange(a, b, 2)
        lon, lat = coords[k], coords[k + 1]
        # small GPS-ish offset, up to ~18 m
        lon += (rng.random() - 0.5) * 0.0002
        lat += (rng.random() - 0.5) * 0.0002
        res = lookup(meta, coords, offsets, grid, lon, lat)
        m = meta[i]
        expected = round(max(m[0], m[1]) if m[0] > 0 and m[1] > 0 else (m[0] or m[1]))
        if expected == 0:
            if res is None:
                zero += 1
            else:
                fail += 1
                print(f"  FAIL seg={i}: zero-limit but found {res}")
            continue
        if res is None:
            fail += 1
            if fail <= 5:
                print(f"  FAIL seg={i}: expected={expected} NOT FOUND")
        else:
            got, dist, _ = res
            if got == expected:
                ok += 1
            elif dist <= 10:
                amb += 1  # crossing road ~10 m away; nearest-segment wins
            else:
                fail += 1
                if fail <= 5:
                    print(f"  FAIL seg={i} expected={expected} got={got} d={dist}m")
    tot = ok + zero + amb + fail
    print(
        f"self-check: {ok} ok | {zero} zero-limit(OK) | {amb} ambiguous(≤10m, OK) | "
        f"{fail} FAIL  of {tot}"
    )
    return fail


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "assets/offline_map/vietnam_speed_limits.geojson"
    meta, coords, offsets, grid = build(path)
    print(f"segments={len(meta)} grid_cells={len(grid)} coords={len(coords) // 2}")
    self_check(meta, coords, offsets, grid)
    tests = [
        ("HCMC", 106.6607, 10.7627),
        ("Hanoi", 105.8342, 21.0278),
        ("Da Nang", 108.2022, 16.0544),
        ("Can Tho", 105.7882, 10.0452),
        ("Nha Trang", 109.1967, 12.2388),
        ("Hai Phong", 106.6886, 20.8454),
        ("Hue", 107.5907, 16.4637),
        ("Buon Ma Thuot", 108.0391, 12.6844),
    ]
    for name, lon, lat in tests:
        print(f"{name:16s} -> {lookup(meta, coords, offsets, grid, lon, lat)}")


if __name__ == "__main__":
    main()
