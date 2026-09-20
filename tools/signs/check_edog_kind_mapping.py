"""Audit the EDOG -> asset KIND mapping actually present in the assets.

`tools/signs/build_vietmap.py` uses the documented KC01 table:
    2 populated · 3 populated_end · 5/6 no_passing(_end) · 7 slow_down ·
    8 toll_booth · 9 tunnel · 4 traffic_camera · 10 speed_camera
`tool/merge_edog_vietmap.py` (older) uses a DIFFERENT one:
    2 speed camera · 3 traffic camera · 4 penalty camera · 5 slow_down ·
    6 toll booth · 7 tunnel · 8 railway · 9 populated · 10 populated_end

Both wrote into the same assets, so a VietMap row's kind may not match the EDOG
row it sits on. This tool measures that by pairing every `source == "vietmap"`
asset row with the nearest EDOG row and reporting the type distribution per kind.

Usage: python3 tools/signs/check_edog_kind_mapping.py
"""

from __future__ import annotations

import collections
import json
import math
import os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MAP = REPO / "assets/offline_map"
EDOG = REPO / "tools/data/vietmap_kc01/edog_data.txt"

# What each asset kind SHOULD map to (documented KC01 table).
EXPECT_SIGN = {
    "populated": {2},
    "populated_end": {3},
    "no_passing": {5},
    "no_passing_end": {6},
    "slow_down": {7},
    "toll_booth": {8},
    "tunnel": {9},
}
EXPECT_CAM = {"traffic_camera": {4}, "speed_camera": {10}}


def metres(a, b):
    dy = (a[0] - b[0]) * 111320.0
    dx = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def main() -> int:
    rows = []
    for line in open(EDOG, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or line.startswith("POINT"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            continue
        try:
            rows.append((int(f[1]) / 1e6, int(f[0]) / 1e6, int(f[2])))
        except ValueError:
            pass
    print(f"EDOG rows: {len(rows)}")

    cell = 0.002
    grid = collections.defaultdict(list)
    for i, r in enumerate(rows):
        grid[(int(r[0] / cell), int(r[1] / cell))].append(i)

    def nearest_type(lat, lng, radius=40.0):
        gx, gy = int(lat / cell), int(lng / cell)
        best = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((gx + dx, gy + dy), ()):
                    r = rows[j]
                    d = metres((lat, lng), (r[0], r[1]))
                    if d <= radius and (best is None or d < best[0]):
                        best = (d, r[2])
        return best[1] if best else None

    signs = json.load(open(MAP / "vietnam_signs.json"))["signs"]
    cams = json.load(open(MAP / "vietnam_cameras.json"))["cameras"]

    print("\nsigns (source=vietmap) — EDOG type found within 40 m:")
    per_kind = collections.defaultdict(collections.Counter)
    for s in signs:
        if s.get("source") != "vietmap" or s.get("kind") not in EXPECT_SIGN:
            continue
        per_kind[s["kind"]][nearest_type(s["lat"], s["lng"])] += 1
    for kind, c in sorted(per_kind.items(), key=lambda kv: -sum(kv[1].values())):
        expect = EXPECT_SIGN[kind]
        total = sum(c.values())
        ok = sum(v for t, v in c.items() if t in expect)
        off = total - ok
        print(f"   {kind:<16} n={total:<6} matching type {sorted(expect)}: {ok:<6} "
              f"WRONG: {off:<6} types seen {dict(c.most_common(4))}")

    print("\ncameras (source=vietmap) — EDOG type found within 40 m:")
    per_type = collections.defaultdict(collections.Counter)
    for c in cams:
        if c.get("source") != "vietmap" or c.get("type") not in EXPECT_CAM:
            continue
        per_type[c["type"]][nearest_type(c["lat"], c["lng"])] += 1
    for t, c in sorted(per_type.items(), key=lambda kv: -sum(kv[1].values())):
        expect = EXPECT_CAM[t]
        total = sum(c.values())
        ok = sum(v for k, v in c.items() if k in expect)
        print(f"   {t:<16} n={total:<6} matching type {sorted(expect)}: {ok:<6} "
              f"WRONG: {total - ok:<6} types seen {dict(c.most_common(4))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
