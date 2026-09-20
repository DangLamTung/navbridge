#!/usr/bin/env python3
"""Dedup the remaining multi-source point layers: POIs + the two offline
speed-limit POINT layers (waze, vietmap). Same 100 m kind-only rule as the
signs/cameras — a same-KIND entry within 100 m collapses to one.

Layers:
  * vietnam_pois.json     — dict keyed by category: {label, emoji, items[]}.
                            key = category (kind) only (per user: "same kind
                            is ok too").
  * waze_speed_limits.json     — {version, points:[{lat,lng,kmh}]}
  * vietmap_speed_limits.json  — {version, points:[{lat,lng,kmh}]}
                            key = kmh (a real limit change 50→60 at one post is
                            a different kmh → both survive; two 50s at the same
                            point collapse).

The speed-limit POINT layers are NOT rendered as icons (they're queried by
speedLimitAt()), so dedup here only removes ambiguous near-identical points to
make the nearest-limit lookup deterministic.

Run from the repo root (navbridge/):
    python3 tools/signs/dedup_points.py            # dry-run
    python3 tools/signs/dedup_points.py --write     # backup + rewrite
"""
import json
import math
import os
import sys
from collections import defaultdict

MAP = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "assets", "offline_map",
))

RADIUS_M = 100.0
R = 6371000


def hav(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dp = math.radians(c - a)
    dl = math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(x))


def spatial_dedup(items, key_fn, lat_fn, lng_fn):
    """Return (kept, dropped) with a 3x3-neighbour, same-key dedup."""
    cell = RADIUS_M / 111320.0
    kept = []
    kept_pts = defaultdict(list)  # key -> kept (lat,lng)
    for it in items:
        k = key_fn(it)
        lat, lng = lat_fn(it), lng_fn(it)
        gx = int(round(lat / cell)); gy = int(round(lng / cell))
        dup = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for (x, y) in kept_pts[(k, gx + dx, gy + dy)]:
                    if hav(x, y, lat, lng) < RADIUS_M:
                        dup = True
                        break
                if dup: break
            if dup: break
        if dup:
            continue
        kept.append(it)
        kept_pts[(k, gx, gy)].append((lat, lng))
    return kept, len(items) - len(kept)


def dedup_pois(write):
    path = os.path.join(MAP, "vietnam_pois.json")
    doc = json.load(open(path))
    total = 0
    dropped = 0
    for cat, v in doc.items():
        if not isinstance(v, dict) or not isinstance(v.get("items"), list):
            continue
        items = v["items"]
        total += len(items)
        kept, d = spatial_dedup(
            items, lambda it: cat, lambda it: float(it["lat"]), lambda it: float(it["lng"]),
        )
        v["items"] = kept
        dropped += d
    print(f"[pois] total={total} dropped={dropped} -> {total-dropped}")
    if write:
        bak = path + ".bak_pre_dedup100"
        if not os.path.exists(bak):
            json.dump(doc, open(bak, "w"), ensure_ascii=False, separators=(",", ":"))
        json.dump(doc, open(path, "w"), ensure_ascii=False, separators=(",", ":"))
        print("    wrote", path)


def dedup_points_file(fname, write):
    path = os.path.join(MAP, fname)
    doc = json.load(open(path))
    pts = doc.get("points", [])
    kept, d = spatial_dedup(
        pts, lambda it: int(it.get("kmh", 0)), lambda it: float(it["lat"]), lambda it: float(it["lng"]),
    )
    print(f"[{fname}] total={len(pts)} dropped={d} -> {len(kept)}")
    if write:
        bak = path + ".bak_pre_dedup100"
        if not os.path.exists(bak):
            json.dump(doc, open(bak, "w"), ensure_ascii=False, separators=(",", ":"))
        doc["version"] = (doc.get("version") or 1) + 1
        doc["points"] = kept
        json.dump(doc, open(path, "w"), ensure_ascii=False, separators=(",", ":"))
        print("    wrote", path)


def main():
    write = "--write" in sys.argv
    dedup_pois(write)
    dedup_points_file("waze_speed_limits.json", write)
    dedup_points_file("vietmap_speed_limits.json", write)
    if not write:
        print("dry-run: pass --write to apply")


if __name__ == "__main__":
    main()
