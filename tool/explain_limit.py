#!/usr/bin/env python3
"""Explain WHERE a spoken/effective speed limit came from.

Replays one position (or every spoken-limit announcement in a trip) against the
same offline layers the app queries, so "the voice said 60 but the road is 50"
can be answered with data instead of guesswork:

  * `vietnam_signs.json`      → the SIGN index (this is what feeds `_signSpeedLimit`
                                via `signsAheadOnRoute`, i.e. the voice/chip value)
  * `waze_speed_limits.json`  → Waze point layer   (checked FIRST by speedLimitAt)
  * `vietmap_speed_limits.json` → VietMap E-DOG point layer
  * `vietnam_speed_limits.geojson` → DATMAP per-segment fwd/rev limit

Usage:
    python3 tool/explain_limit.py <trip.json> [--time HH:MM:SS] [--all]
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
from datetime import datetime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(REPO, "assets/offline_map")

# The app's own search windows (see offline_speed_limits.dart / nav_signs.dart).
POINT_WINDOW_M = 25      # speedLimitAt(): nearest posted point within 25 m
SEGMENT_WINDOW_M = 25    # speedLimitAt(): nearest DATMAP segment within 25 m
SIGN_WINDOW_M = 400      # nav_signs.dart: a speed sign <=400 m ahead takes effect


def hav(a, b):
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def pt_dist_m(a, b):
    """Approximate local planar distance (fast; fine at these ranges)."""
    dy = (a[0] - b[0]) * 111320.0
    dx = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def load_points(name):
    with open(os.path.join(MAP, name), encoding="utf-8") as f:
        d = json.load(f)
    return [(p["lat"], p["lng"], p["kmh"]) for p in d["points"] if p.get("kmh")]


def nearest_point(pts, pos):
    best = None
    for lat, lng, kmh in pts:
        if abs(lat - pos[0]) > 0.004 or abs(lng - pos[1]) > 0.004:
            continue
        d = pt_dist_m(pos, (lat, lng))
        if best is None or d < best[0]:
            best = (d, kmh, lat, lng)
    return best


def load_signs():
    with open(os.path.join(MAP, "vietnam_signs.json"), encoding="utf-8") as f:
        d = json.load(f)
    return [
        (s["lat"], s["lng"], s.get("value"), s.get("source"))
        for s in d["signs"]
        if s.get("kind") == "speed" and s.get("value")
    ]


def load_datmap():
    with open(
        os.path.join(MAP, "vietnam_speed_limits.geojson"), encoding="utf-8"
    ) as f:
        d = json.load(f)
    segs = []
    for ft in d["features"]:
        p = ft.get("properties") or {}
        fwd, rev = p.get("fwdMaxSpeed"), p.get("revMaxSpeed")
        g = ft.get("geometry") or {}
        if g.get("type") == "LineString":
            lines = [g["coordinates"]]
        elif g.get("type") == "MultiLineString":
            lines = g["coordinates"]
        else:
            continue
        for line in lines:
            segs.append((fwd, rev, [(c[1], c[0]) for c in line]))
    return segs


def nearest_segment(segs, pos):
    """Point-to-segment distance, the same 25 m window speedLimitAt uses."""
    best = None
    for fwd, rev, line in segs:
        for (alat, alng), (blat, blng) in zip(line[:-1], line[1:]):
            if min(alat, blat) - 0.004 > pos[0] or max(alat, blat) + 0.004 < pos[0]:
                continue
            if min(alng, blng) - 0.004 > pos[1] or max(alng, blng) + 0.004 < pos[1]:
                continue
            ax, ay = alng, alat
            bx, by = blng, blat
            px, py = pos[1], pos[0]
            dx, dy = bx - ax, by - ay
            if dx == 0 and dy == 0:
                t = 0.0
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
                t = max(0.0, min(1.0, t))
            cx, cy = ax + t * dx, ay + t * dy
            d = pt_dist_m(pos, (cy, cx))
            if best is None or d < best[0]:
                best = (d, fwd, rev)
    return best


def explain(pos, label=""):
    print(f"\n=== {label} @ {pos[0]:.6f},{pos[1]:.6f}")
    signs = SIGN_CACHE
    near_signs = sorted(
        ((pt_dist_m(pos, (la, ln)), v, src) for la, ln, v, src in signs),
        key=lambda x: x[0],
    )[:4]
    for d, v, src in near_signs:
        mark = "  <-- feeds _signSpeedLimit" if d <= SIGN_WINDOW_M else ""
        print(f"  sign      {v:>4} km/h  {d:7.1f} m  source={src}{mark}")
    for name, pts in (("waze", WAZE), ("vietmap", VIETMAP)):
        r = nearest_point(pts, pos)
        if r:
            d, kmh, _, _ = r
            note = " (ACCEPTED)" if d <= POINT_WINDOW_M else f" (outside {POINT_WINDOW_M} m)"
            print(f"  {name:<9} {kmh:>4} km/h  {d:7.1f} m{note}")
    seg = nearest_segment(DATMAP, pos)
    if seg:
        d, fwd, rev = seg
        note = " (ACCEPTED)" if d <= SEGMENT_WINDOW_M else f" (outside {SEGMENT_WINDOW_M} m)"
        print(f"  datmap    fwd={fwd} rev={rev} (max {max(f for f in (fwd, rev) if f) if any((fwd, rev)) else '-'})  {d:7.1f} m{note}")


def main() -> int:
    global SIGN_CACHE, WAZE, VIETMAP, DATMAP
    ap = argparse.ArgumentParser()
    ap.add_argument("trip")
    ap.add_argument("--time", help="HH:MM:SS of the announcement")
    ap.add_argument("--all", action="store_true", help="every spoken-limit line")
    args = ap.parse_args()

    print("loading layers…")
    SIGN_CACHE = load_signs()
    WAZE = load_points("waze_speed_limits.json")
    VIETMAP = load_points("vietmap_speed_limits.json")
    DATMAP = load_datmap()
    print(f"  signs={len(SIGN_CACHE)} waze={len(WAZE)} vietmap={len(VIETMAP)} "
          f"datmap_segments={len(DATMAP)}")

    with open(args.trip, encoding="utf-8") as f:
        d = json.load(f)
    anns = d.get("announcements") or []
    for a in anns:
        t = a.get("time") or ""
        hhmm = t[11:19]
        if not args.all and args.time and hhmm != args.time:
            continue
        if not args.all and not args.time and "iới hạn" not in (a.get("text") or ""):
            continue
        if a.get("lat") is None:
            continue
        if "km/h" not in (a.get("text") or ""):
            continue
        explain((a["lat"], a["lng"]), f"{hhmm} {a['text']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
