#!/usr/bin/env python3
"""Dedup vietnam_signs.json spatially and prefer the richest source.

Why: the sign layer is merged from OSM Overpass + Waze point-notices + VietMap
E-DOG, and the crawl tiles overlap, so the SAME physical sign appears several
times at sub-metre offsets. A server-side 5dp dedup in the merge scripts
couldn't merge those. Worse, the same physical sign is often recorded at
~40-80 m offsets across sources, so a small radius still left 5-7 overlapping
icons for one real posted limit (the user: "multiple sign near by", then
"open to 100m, same kind is ok too" — i.e. collapse same-kind signs within
100 m EVEN IF their posted value differs).

Rules (per user 2026-09-08):
  * dedup radius 100 m, keyed by KIND ONLY (value is NOT part of the key) —
    the driver wants ONE icon per sign post, so an 80 and a 90 recorded at the
    same post (by different sources) collapse to a single sign rather than
    stacking. The road-info/statutory layer still carries the per-segment limit.
  * a STOP and a speed sign at one post are different kinds → both kept,
  * source priority: vietmap(0) > waze(1) > osm(2), so the richest/clearest
    source wins any collapsed cluster,
  * ties keep the FIRST (already sorted by priority).

Run from the repo root (navbridge/):
    python3 tools/signs/dedup_signs.py            # dry-run (prints counts)
    python3 tools/signs/dedup_signs.py --write     # backup + rewrite asset
"""
import json
import math
import os
import sys
from collections import defaultdict

ASSET = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "assets", "offline_map",
    "vietnam_signs.json",
))

RADIUS_M = 100.0
R = 6371000

# source priority (lower wins) — the richest / most authoritative first.
SRC_PRIORITY = {"vietmap": 0, "waze": 1, "osm": 2}


def hav(a, b, c, dd):
    p1, p2 = math.radians(a), math.radians(c)
    dp = math.radians(c - a)
    dl = math.radians(dd - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(x))


def key(s):
    """Dedup key: KIND ONLY. The user wants one icon per post, so a same-kind
    sign within the radius collapses regardless of value."""
    return s.get("kind", "")


def main():
    write = "--write" in sys.argv
    doc = json.load(open(ASSET))
    signs = doc["signs"]
    print("input signs:", len(signs))

    def prio(s):
        return SRC_PRIORITY.get(str(s.get("source")), 99)

    signs.sort(key=prio)

    cell = RADIUS_M / 111320.0
    grid = defaultdict(list)
    for i, s in enumerate(signs):
        k = (key(s), round(s["lat"] / cell), round(s["lng"] / cell))
        grid[k].append(i)

    keep = []
    kept_pts = defaultdict(list)  # kind -> kept (lat,lng)
    for ((k, gx, gy)), idxs in grid.items():
        for i in idxs:
            s = signs[i]
            dup = False
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for (x, y) in kept_pts[(k, gx + dx, gy + dy)]:
                        if hav(x, y, s["lat"], s["lng"]) < RADIUS_M:
                            dup = True
                            break
                    if dup:
                        break
                if dup:
                    break
            if dup:
                continue
            keep.append(s)
            kept_pts[(k, gx, gy)].append((s["lat"], s["lng"]))

    print("after dedup @100m (per kind):", len(keep),
          "(dropped", len(signs) - len(keep), ")")

    if not write:
        print("dry-run: no files changed (pass --write to apply)")
        return 0

    bak = ASSET + ".bak_pre_dedup3"
    if not os.path.exists(bak):
        json.dump(doc, open(bak, "w"), ensure_ascii=False, separators=(",", ":"))
        print("backup:", os.path.basename(bak))

    doc["signs"] = keep
    json.dump(doc, open(ASSET, "w"), ensure_ascii=False, separators=(",", ":"))
    print("wrote", ASSET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
