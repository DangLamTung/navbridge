#!/usr/bin/env python3
"""Audit WHERE camera points sit relative to the road network.

The VietMap `traffic_camera` points (24k, 76% of the DB) are suspected of not
lying on the roads they claim. This measures each point's distance to the
nearest DATMAP road segment (real road geometry, bundled) and compares camera
types against each other, plus reports coordinate precision (a 0.001° grid =
~111 m, which alone would put points "off the road").

Usage: python3 tool/audit_camera_placement.py [--sample 400]
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import random

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(REPO, "assets/offline_map")


def pt_seg_m(p, a, b):
    """Metres from point p=(lat,lng) to segment a→b (lat,lng)."""
    dy = 111320.0
    dx = 111320.0 * math.cos(math.radians(p[0]))
    ax, ay = a[1] * dx, a[0] * dy
    bx, by = b[1] * dx, b[0] * dy
    px, py = p[1] * dx, p[0] * dy
    vx, vy = bx - ax, by - ay
    if vx == 0 and vy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def load_roads():
    with open(os.path.join(MAP, "vietnam_speed_limits.geojson"), encoding="utf-8") as f:
        d = json.load(f)
    segs = []
    for ft in d["features"]:
        g = ft.get("geometry") or {}
        lines = [g["coordinates"]] if g.get("type") == "LineString" else (
            g["coordinates"] if g.get("type") == "MultiLineString" else [])
        for line in lines:
            pts = [(c[1], c[0]) for c in line]
            for a, b in zip(pts[:-1], pts[1:]):
                segs.append((a, b))
    # Grid index so the scan is not 93k segments × N points.
    grid = collections.defaultdict(list)
    for i, (a, b) in enumerate(segs):
        la = (a[0] + b[0]) / 2
        ln = (a[1] + b[1]) / 2
        grid[(round(la, 2), round(ln, 2))].append(i)
    return segs, grid


def near_road_m(pos, segs, grid):
    best = None
    for dla in (-0.02, -0.01, 0.0, 0.01, 0.02):
        for dln in (-0.02, -0.01, 0.0, 0.01, 0.02):
            for i in grid.get((round(pos[0] + dla, 2), round(pos[1] + dln, 2)), ()):
                a, b = segs[i]
                d = pt_seg_m(pos, a, b)
                if best is None or d < best:
                    best = d
            if best is not None and best < 20:
                return best
    return best


def pct(xs, q):
    if not xs:
        return 0.0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=300)
    args = ap.parse_args()
    random.seed(7)

    cams = json.load(open(os.path.join(MAP, "vietnam_cameras.json")))["cameras"]
    print(f"cameras: {len(cams)}")
    segs, grid = load_roads()
    print(f"road segments (DATMAP): {len(segs)}")

    groups = collections.defaultdict(list)
    for c in cams:
        groups[(c.get("source"), c.get("type") or "-")].append((c["lat"], c["lng"]))

    print(f"\n{'source':<9}{'type':<18}{'n':>7}{'in DB':>8}"
          f"{'med m':>8}{'p90 m':>8}{'<25m':>7}{'<100m':>7}{'3dp':>7}")
    for (src, typ), pts in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        sample = random.sample(pts, min(args.sample, len(pts)))
        ds = []
        for p in sample:
            d = near_road_m(p, segs, grid)
            if d is not None:
                ds.append(d)
        off = sum(1 for la, ln in sample if abs(la * 1e6) % 1000 == 0)
        print(f"{src or '?':<9}{typ:<18}{len(sample):>7}{len(pts):>8}"
              f"{pct(ds, .5):>8.0f}{pct(ds, .9):>8.0f}"
              f"{sum(1 for d in ds if d < 25) / max(1, len(ds)) * 100:>6.0f}%"
              f"{sum(1 for d in ds if d < 100) / max(1, len(ds)) * 100:>6.0f}%"
              f"{off / max(1, len(sample)) * 100:>6.0f}%")
    print("\n'3dp' = share of sampled points whose latitude sits exactly on a "
          "0.001° grid (~111 m) — coarse coordinates put a point off the road.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
