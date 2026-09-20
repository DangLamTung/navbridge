#!/usr/bin/env python3
"""Dedup vietnam_cameras.json spatially (per-focus, ~100 m) and prefer the
richest source.

Why: the crawl tiles overlap AND we merge from multiple sources (Waze / VietMap
EDOG / police CSGT / OSM), so the SAME physical camera appears several times at
sub-metre offsets — e.g. a Waze row sitting on top of a VietMap row for the
same enforcement camera. The earlier rebuild used a ~1 m coordinate dedup,
which couldn't merge these. The user: "camera too since we use multiple data
source" — same treatment as the signs (100 m, kind-only).

Rules:
  * dedup radius 100 m, keyed by `focus` (a red-light cam and a speed cam are
    different alerts, even at the same spot),
  * source priority: vietmap(0) > waze(1) > police(2) > osm(3) > none(4),
  * a lower-priority camera within the radius of a kept higher-priority one is
    dropped (so waze rows duplicate of vietmap are removed),
  * anonymous `source` missing cameras are tagged `waze` (they come from the
    same WME permanentHazards type-10 crawl layer) so they are not ambiguous.

Run from the repo root (navbridge/):
    python3 tools/signs/dedup_cameras.py
"""
import json
import math
import os
import sys
from collections import defaultdict

ASSET = os.path.join(
    os.path.dirname(__file__), "..", "..", "assets", "offline_map",
    "vietnam_cameras.json",
)
ASSET = os.path.abspath(ASSET)

RADIUS_M = 100.0
R = 6371000

# source priority (lower wins)
SRC_PRIORITY = {"vietmap": 0, "waze": 1, "police": 2, "osm": 3, "none": 4}


def hav(a, b, c, dd):
    p1, p2 = math.radians(a), math.radians(c)
    dp = math.radians(c - a)
    dl = math.radians(dd - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(math.sqrt(x))


def main():
    doc = json.load(open(ASSET))
    cams = doc["cameras"]
    print("input cameras:", len(cams))

    # Tag anonymous (source missing) cameras as 'waze' — they come from the
    # same WME permanentHazards type-10 crawl layer as the tagged waze ones.
    for c in cams:
        if c.get("source") is None:
            c["source"] = "waze"

    # Sort by (source priority, then keep original order) so we always keep the
    # highest-priority source first.
    def prio(c):
        return SRC_PRIORITY.get(str(c.get("source")), 99)

    cams.sort(key=prio)

    cell = RADIUS_M / 111320.0
    grid = defaultdict(list)
    for i, c in enumerate(cams):
        key = (c.get("focus", ""), round(c["lat"] / cell), round(c["lng"] / cell))
        grid[key].append(i)

    keep = []
    kept_pts = defaultdict(list)  # focus -> kept (lat,lng)
    for (focus, gx, gy), idxs in grid.items():
        for i in idxs:
            c = cams[i]
            # check against already-kept same-focus points in adjacent cells
            dup = False
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for (x, y) in kept_pts[(focus, gx + dx, gy + dy)]:
                        if hav(x, y, c["lat"], c["lng"]) < RADIUS_M:
                            dup = True
                            break
                    if dup:
                        break
                if dup:
                    break
            if dup:
                continue
            keep.append(c)
            kept_pts[(focus, gx, gy)].append((c["lat"], c["lng"]))

    doc["cameras"] = keep
    # backup
    bak = ASSET + ".bak_pre_dedup100"
    if not os.path.exists(bak):
        json.dump(json.load(open(ASSET)), open(bak, "w"), ensure_ascii=False)
    json.dump(doc, open(ASSET, "w"), ensure_ascii=False, separators=(",", ":"))

    from collections import Counter
    print("after dedup @100m (per focus):", len(keep))
    print("by source:", dict(Counter(c.get("source") for c in keep).most_common()))
    print("by focus:", dict(Counter(c.get("focus") for c in keep).most_common()))
    print("backup:", os.path.basename(bak))


if __name__ == "__main__":
    main()
