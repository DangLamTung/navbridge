#!/usr/bin/env python3
"""Repair the truncated VietMap coordinates in the bundled data assets.

WHY: `build_vietmap.py` dedups E-DOG rows into a 0.001° cell (~111 m) and then
writes the CELL's rounded coordinate instead of the stored one, so every
VietMap point it added sits on a ~111 m grid — up to ~78 m from the real spot.
That is why the VietMap traffic cameras (76% of the camera DB) do not line up
with the road they belong to.

WHAT: for every grid-snapped `source == "vietmap"` row, look up the E-DOG row it
was made from (same type, same ~100 m cell) and rewrite its lat/lng with the
precise source coordinate. Non-VietMap rows and already-precise VietMap rows are
untouched.

Usage:
    python3 tools/signs/fix_vietmap_precision.py            # dry run
    python3 tools/signs/fix_vietmap_precision.py --write    # backup + rewrite
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import shutil
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MAP = REPO / "assets/offline_map"
CAM = MAP / "vietnam_cameras.json"
SIGN = MAP / "vietnam_signs.json"

# E-DOG type codes (see tools/signs/build_vietmap.py).
EDOG_CAM_TYPE = {"traffic_camera": 4, "speed_camera": 10}
EDOG_SIGN_TYPE = {
    "populated": 2,
    "populated_end": 3,
    "no_passing": 5,
    "no_passing_end": 6,
    "slow_down": 7,
    "toll_booth": 8,
    "tunnel": 9,
}


def find_edog() -> Path:
    roots = [REPO / "tools/data/vietmap_kc01", Path("/Users/tungdl/Documents/Eink/Decode_Waze")]
    best = None
    for root in roots:
        if not root.exists():
            continue
        for p in root.rglob("edog_data.txt"):
            if best is None or p.stat().st_mtime > best.stat().st_mtime:
                best = p
    if best is None:
        sys.exit("edog_data.txt not found")
    return best


def parse_edog(path: Path):
    """Precise (lat, lng, type, speed) rows — POINT_X/POINT_Y are 1e-6 degrees."""
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or line.startswith("POINT"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            continue
        try:
            lng = int(f[0]) / 1e6
            lat = int(f[1]) / 1e6
            t = int(f[2])
            spd = int(f[3])
        except ValueError:
            continue
        rows.append((lat, lng, t, spd))
    return rows


def on_grid(v: float) -> bool:
    """True when the value sits exactly on the 0.001° grid (i.e. truncated)."""
    return abs(round(v, 6) * 1e6) % 1000 < 0.5


def metres(a, b):
    dy = (a[0] - b[0]) * 111320.0
    dx = (a[1] - b[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--edog", help="path to edog_data.txt")
    args = ap.parse_args()

    src = Path(args.edog) if args.edog else find_edog()
    print(f"edog: {src}")
    rows = parse_edog(src)
    print(f"  rows: {len(rows)}")

    # type → cell → [rows] (cell = 0.001° grid, the unit build_vietmap deduped on)
    by_type_cell = collections.defaultdict(lambda: collections.defaultdict(list))
    for i, (lat, lng, t, _) in enumerate(rows):
        by_type_cell[t][(round(lat, 3), round(lng, 3))].append(i)
    used: set[int] = set()

    def repair(items, allowed_types, label):
        fixed = 0
        skipped = 0
        unmatched = 0
        moves = []
        for it in items:
            lat, lng = it["lat"], it["lng"]
            if not (on_grid(lat) and on_grid(lng)):
                skipped += 1
                continue
            cands = []
            for t in allowed_types:
                for dla in (-0.001, 0.0, 0.001):
                    for dln in (-0.001, 0.0, 0.001):
                        key = (round(lat + dla, 3), round(lng + dln, 3))
                        cands.extend(by_type_cell[t].get(key, ()))
            if not cands:
                unmatched += 1
                continue
            free = [i for i in cands if i not in used] or cands
            best = min(free, key=lambda i: metres((lat, lng), rows[i][:2]))
            used.add(best)
            plat, plng = rows[best][0], rows[best][1]
            moves.append(metres((lat, lng), (plat, plng)))
            it["lat"] = round(plat, 6)
            it["lng"] = round(plng, 6)
            fixed += 1
        moves.sort()
        med = moves[len(moves) // 2] if moves else 0
        print(
            f"  {label}: repaired {fixed}, already precise {skipped}, "
            f"no source match {unmatched} | moved median {med:.0f} m, "
            f"max {moves[-1] if moves else 0:.0f} m"
        )
        return fixed

    cam_doc = json.load(open(CAM, encoding="utf-8"))
    cams = cam_doc["cameras"]
    vm_cams = [
        c
        for c in cams
        if c.get("source") == "vietmap" and c.get("type") in EDOG_CAM_TYPE
    ]
    print(f"\ncameras: {len(cams)} total, {len(vm_cams)} VietMap typed")
    n1 = repair(
        vm_cams,
        {EDOG_CAM_TYPE[c["type"]] for c in vm_cams},
        "cameras",
    )

    sign_doc = json.load(open(SIGN, encoding="utf-8"))
    signs = sign_doc["signs"]
    vm_signs = [
        s
        for s in signs
        if s.get("source") == "vietmap" and s.get("kind") in EDOG_SIGN_TYPE
    ]
    print(f"\nsigns: {len(signs)} total, {len(vm_signs)} VietMap sign-kind")
    n2 = repair(
        vm_signs,
        {EDOG_SIGN_TYPE[s["kind"]] for s in vm_signs},
        "signs",
    )

    if not args.write:
        print("\nDRY RUN — nothing written. Re-run with --write.")
        return 0

    # The repair can land two rows of the SAME kind on one source point (the
    # 3x3 cell search reuses a row when a cell held more asset rows than E-DOG
    # rows). Collapse those identical (kind, lat, lng) rows — the app's own
    # dedup treats them as one sign anyway.
    seen_keys = set()
    kept = []
    for s in signs:
        k = (s.get("kind"), round(s["lat"], 5), round(s["lng"], 5))
        if k in seen_keys:
            continue
        seen_keys.add(k)
        kept.append(s)
    dropped = len(signs) - len(kept)
    if dropped:
        sign_doc["signs"] = kept
        print(f"  deduped {dropped} identical sign rows")

    stamp = time.strftime("%Y%m%d_%H%M%S")
    for path, doc in ((CAM, cam_doc), (SIGN, sign_doc)):
        shutil.copy2(path, f"{path}.{stamp}.bak")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
        print(f"wrote {path} (backup .{stamp}.bak)")
    print(f"\nrepaired {n1 + n2} points, dropped {dropped} duplicates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
