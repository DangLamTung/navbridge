#!/usr/bin/env python3
"""Fill the missing `speed_limit` on speed cameras.

WHY: the E-DOG `Speed` column is only populated for TYPE 1 (posted limits); the
camera rows (types 4 and 10) always carry 0, and `build_vietmap.py` copied that
column verbatim — so `speed_limit` is empty for all 31,704 camera rows and the
app can never say "Camera tốc độ 80 km/h".

WHAT: for every speed camera, resolve the posted limit from
  1. the camera NAME (Waze stores it there: "Waze speed camera 80 km/h"), then
  2. the nearest posted-limit point in `waze_speed_limits.json` /
     `vietmap_speed_limits.json` within --max-dist metres.

Usage:
    python3 tools/signs/fill_camera_speed_limits.py            # dry run
    python3 tools/signs/fill_camera_speed_limits.py --write
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import re
import shutil
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MAP = REPO / "assets/offline_map"
CAM = MAP / "vietnam_cameras.json"
POINT_LAYERS = ("waze_speed_limits.json", "vietmap_speed_limits.json")

NAME_LIMIT = re.compile(r"(\d{2,3})\s*(?:km/h|kmh|kph)", re.IGNORECASE)


def metres(a, b):
    dy = (a[0] - b[0]) * 111320.0
    dx = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def load_point_grid():
    grid = collections.defaultdict(list)
    n = 0
    for name in POINT_LAYERS:
        path = MAP / name
        if not path.exists():
            continue
        for p in json.load(open(path, encoding="utf-8")).get("points", []):
            kmh = p.get("kmh") or 0
            if kmh <= 0:
                continue
            grid[(round(p["lat"], 2), round(p["lng"], 2))].append((p["lat"], p["lng"], kmh))
            n += 1
    return grid, n


def nearest_limit(grid, pos, max_dist):
    best = None
    for dla in (-0.01, 0.0, 0.01):
        for dln in (-0.01, 0.0, 0.01):
            for lat, lng, kmh in grid.get((round(pos[0] + dla, 2), round(pos[1] + dln, 2)), ()):
                d = metres(pos, (lat, lng))
                if d <= max_dist and (best is None or d < best[0]):
                    best = (d, kmh)
    return best


def load_segment_grid():
    """DATMAP per-segment limits, grid-indexed (the app's 3rd layer)."""
    path = MAP / "vietnam_speed_limits.geojson"
    if not path.exists():
        return collections.defaultdict(list), 0
    grid = collections.defaultdict(list)
    n = 0
    for ft in json.load(open(path, encoding="utf-8"))["features"]:
        props = ft.get("properties") or {}
        fwd, rev = props.get("fwdMaxSpeed") or 0, props.get("revMaxSpeed") or 0
        kmh = max(fwd, rev)
        g = ft.get("geometry") or {}
        lines = [g["coordinates"]] if g.get("type") == "LineString" else (
            g["coordinates"] if g.get("type") == "MultiLineString" else [])
        for line in lines:
            pts = [(c[1], c[0]) for c in line]
            for (alat, alng), (blat, blng) in zip(pts[:-1], pts[1:]):
                mid = ((alat + blat) / 2, (alng + blng) / 2)
                grid[(round(mid[0], 2), round(mid[1], 2))].append((alat, alng, blat, blng, kmh))
                n += 1
    return grid, n


def seg_dist_m(pos, a, b):
    dy = 111320.0
    dx = 111320.0 * math.cos(math.radians(pos[0]))
    ax, ay = a[1] * dx, a[0] * dy
    bx, by = b[1] * dx, b[0] * dy
    px, py = pos[1] * dx, pos[0] * dy
    vx, vy = bx - ax, by - ay
    if vx == 0 and vy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def nearest_segment_limit(seggrid, pos, max_dist):
    best = None
    for dla in (-0.01, 0.0, 0.01):
        for dln in (-0.01, 0.0, 0.01):
            for alat, alng, blat, blng, kmh in seggrid.get(
                (round(pos[0] + dla, 2), round(pos[1] + dln, 2)), ()
            ):
                d = seg_dist_m(pos, (alat, alng), (blat, blng))
                if d <= max_dist and (best is None or d < best[0]):
                    best = (d, kmh)
    return best


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--max-dist", type=float, default=30.0,
                    help="metres to search for a posted-limit point (default 30)")
    args = ap.parse_args()

    grid, n_pts = load_point_grid()
    print(f"posted-limit points loaded: {n_pts}")
    seggrid, n_segs = load_segment_grid()
    print(f"DATMAP road segments loaded: {n_segs}")

    doc = json.load(open(CAM, encoding="utf-8"))
    cams = doc["cameras"]
    speed_cams = [c for c in cams if c.get("focus") == "speed"]
    print(f"camera rows: {len(cams)} | speed-focus: {len(speed_cams)}")

    by_name = by_point = unresolved = already = 0
    examples = []
    for c in speed_cams:
        if (c.get("speed_limit") or 0) > 0:
            already += 1
            continue
        m = NAME_LIMIT.search(c.get("name") or "")
        if m:
            c["speed_limit"] = int(m.group(1))
            by_name += 1
            if len(examples) < 4:
                examples.append((c["name"], c["speed_limit"]))
            continue
        hit = nearest_limit(grid, (c["lat"], c["lng"]), args.max_dist)
        if not hit and seggrid:
            hit = nearest_segment_limit(seggrid, (c["lat"], c["lng"]), args.max_dist)
        if hit:
            c["speed_limit"] = int(hit[1])
            by_point += 1
            if len(examples) < 8:
                examples.append((f"{c.get('source')} {c['lat']:.5f},{c['lng']:.5f}",
                                 c["speed_limit"], round(hit[0])))
        else:
            unresolved += 1

    print(f"  already set: {already}")
    print(f"  resolved from NAME: {by_name}")
    print(f"  resolved from a nearby posted-limit point: {by_point}")
    print(f"  left empty (voice says just 'Camera tốc độ'): {unresolved}")
    print("  examples:", examples)
    dist = collections.Counter(c.get("speed_limit") for c in speed_cams if c.get("speed_limit"))
    print("  limit distribution:", dict(sorted(dist.items(), key=lambda kv: -kv[1])[:10]))

    if not args.write:
        print("\nDRY RUN — nothing written. Re-run with --write.")
        return 0
    stamp = time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(CAM, f"{CAM}.{stamp}.bak")
    with open(CAM, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {CAM} (backup .{stamp}.bak)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
