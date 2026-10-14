#!/usr/bin/env python3
"""Generate `one_way` (I.407a) sign rows from the SEGMENT layer's one-way data.

Why this exists (user, 2026-10-11): "what i mean is when go to intersect with 1
way street u should have announce, or better have the sign for these street (the
one way street), add one way street sign at start and end of these street".

The app already renders I.407a (`lib/ui/sign_icons.dart` -> `one_way.png`), already
lists `RoadSignKind.oneWay` among the ANNOUNCED kinds (`nav_signs.dart`), and the
voice pack already has "Đường một chiều sắp tới" / "… phía trước {distance}"
(`tools/voice_phrases.json`). What it did NOT have is data: the pack holds only
**10** `one_way` rows nationwide, all from Waze map comments, none in District 1.

The signal was already in `waze_segments.bin` all along: the builder zeroes the
speed of every direction WME marks as not drivable, so "exactly one of fwd/rev is
nonzero" IS a one-way flag (161,401 segments = 15.8% nationwide; 1,688 in the
District 1 bbox). This reads that asset and writes ONE sign at each end of every
one-way RUN, so both approaches to the street see the sign.

Only the geometry+direction is used — no new crawl, no rebuild of the 28 MB
segment asset.

Run:
    python3 tools/signs/build_oneway_signs.py --dry-run     # counts only
    python3 tools/signs/build_oneway_signs.py --write       # backs up, then writes
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

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tool"))
from waze_segments import Segments  # noqa: E402

ASSET = ROOT / "assets" / "offline_map" / "waze_segments.bin"
SIGNS = ROOT / "assets" / "offline_map" / "vietnam_signs.json"
SOURCE = "waze-segment"
NAME = "Đường một chiều"

# Two one-way segments belong to the same run when the exit of one is within
# this of the entry of the next. Waze splits a street into ~20-40 m segments and
# leaves small gaps at junctions, so this only has to span a junction.
JOIN_M = 45.0
# Never emit two signs of the same kind within this many metres. The pack's OWN
# invariant is `test/data_integrity_test.dart` / `validate_sign_placement.py`:
# no same-kind pair within 80 m, measured with HAVERSINE while this file measures
# equirectangular. A pair at ~79.9 m haversine can read as 80.1 m here, so the
# margin is 85 m — at exactly 80 the gate still found 6 pairs. A run must be at
# least this long for BOTH of its ends to carry a sign.
DEDUP_M = 85.0


def metres(a: tuple[float, float], b: tuple[float, float]) -> float:
    dlat = (b[0] - a[0]) * 111320.0
    dlng = (b[1] - a[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dlat, dlng)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="actually write the pack")
    ap.add_argument("--dry-run", action="store_true", default=False)
    ap.add_argument("--min-run-m", type=float, default=None,
                    help="skip one-way runs shorter than this (default: DEDUP_M, so "
                         "both ends of a kept run satisfy the 80 m pack invariant)")
    ap.add_argument("--keep-unnamed", action="store_true",
                    help="also emit signs on unnamed runs (default: skip them)")
    ap.add_argument("--max-rows", type=int, default=60000,
                    help="refuse to write more rows than this (sanity gate)")
    args = ap.parse_args()
    if args.min_run_m is None:
        args.min_run_m = DEDUP_M

    seg = Segments(str(ASSET))
    n = seg.n_segs
    print(f"segments: {n:,}")

    # --- collect the one-way segments, oriented along the ALLOWED direction ---
    by_route: dict[tuple[str, int], list[tuple[int, tuple, tuple]]] = (
        collections.defaultdict(list))
    one_way = 0
    for s in range(n):
        f, r = seg.fwd[s], seg.rev[s]
        if bool(f) == bool(r):
            continue  # two-way (both) or unusable (neither)
        one_way += 1
        pts = seg.pts[s]
        if len(pts) < 2:
            continue
        # fwd>0 -> allowed along the stored order; rev>0 -> against it
        entry, exit_ = (pts[0], pts[-1]) if f else (pts[-1], pts[0])
        by_route[(seg.street(s) or "", 1 if f else -1)].append((s, entry, exit_))
    print(f"one-way segments: {one_way:,} in {len(by_route):,} (street,direction) groups")

    # --- chain each group into runs by greedy adjacency on the exit point ------
    runs: list[tuple[tuple, tuple, str]] = []
    for (street, _dir), items in by_route.items():
        pool = list(items)
        used = [False] * len(pool)
        for i in range(len(pool)):
            if used[i]:
                continue
            used[i] = True
            run_entry, run_exit = pool[i][1], pool[i][2]
            grew = True
            while grew:
                grew = False
                best, best_d = -1, JOIN_M
                for j in range(len(pool)):
                    if used[j]:
                        continue
                    d = metres(run_exit, pool[j][1])
                    if d < best_d:
                        best, best_d = j, d
                if best >= 0:
                    used[best] = True
                    run_exit = pool[best][2]
                    grew = True
            runs.append((run_entry, run_exit, street))
    print(f"one-way RUNS: {len(runs):,}")

    # --- keep only runs that are plausibly a one-way STREET -------------------
    # A one-way run shorter than a car length is a junction connector or a
    # slip-lane fragment: a sign at each end of it would be noise, and it is the
    # main reason the raw run count (43k) overstates the real number of one-way
    # streets. Same for unnamed runs — Waze leaves 62% of segments unnamed.
    # --- ONLY genuinely one-way STREETS --------------------------------------
    # ⛔ A DIVIDED road is stored in WME as TWO one-way carriageways, so the
    # per-SEGMENT flag says "one-way" on BOTH sides of an arterial. Trusting it
    # put "Đường một chiều" signs on Cộng Hòa, Trường Chinh, QL1, Nguyễn Văn
    # Linh ... Measured 2026-10-11 with tool/oneway_street_audit.py: 1,914 of
    # the street names look one-way in part but carry BOTH directions somewhere
    # — 82.5% of all one-way-looking segments. A one-way sign is only correct
    # when the WHOLE street is one-way, i.e. NO segment of it is two-way.
    two_way: set[str] = set()
    for s in range(seg.n_segs):
        if seg.fwd[s] and seg.rev[s]:
            nm = seg.street(s)
            if nm:
                two_way.add(nm)

    def in_vn(pt) -> bool:
        """Vietnam only — the crawl also covers Thailand (ถนนมิตรภาพ, ทล.226)."""
        return 8.0 <= float(pt[0]) <= 24.0 and 102.0 <= float(pt[1]) <= 110.0

    kept_runs = [
        (e, x, st) for (e, x, st) in runs
        if metres((float(e[0]), float(e[1])), (float(x[0]), float(x[1]))) >= args.min_run_m
        and (args.keep_unnamed or st)
        and st not in two_way        # the WHOLE street must be one-way
        and in_vn(e) and in_vn(x)    # and inside Vietnam
    ]
    dropped_short = sum(
        1 for (e, x, _st) in runs
        if metres((float(e[0]), float(e[1])), (float(x[0]), float(x[1]))) < args.min_run_m)
    dropped_unnamed = sum(
        1 for (e, x, st) in runs if not st
        and metres((float(e[0]), float(e[1])), (float(x[0]), float(x[1]))) >= args.min_run_m)
    dropped_two_way = sum(1 for (e, x, st) in runs if st in two_way)
    dropped_foreign = sum(1 for (e, x, _st) in runs
                          if not in_vn(e) or not in_vn(x))
    print(f"  streets proven TWO-WAY somewhere: {len(two_way):,}")
    print(f"  kept {len(kept_runs):,} runs (>={args.min_run_m:.0f} m, named, "
          f"whole street one-way, in VN) — dropped {dropped_short:,} short, "
          f"{dropped_unnamed:,} unnamed, {dropped_two_way:,} on TWO-WAY "
          f"streets, {dropped_foreign:,} outside VN"
          f" -> candidate signs: {len(kept_runs) * 2:,}")

    # --- drop candidates that collide (the same junction, both directions) ----
    # The grid is SEEDED with the `one_way` rows already in the pack (the Waze
    # map-comment ones, a different `source`) because the invariant the gate
    # checks is "no same-kind pair within 80 m" across ALL sources — 6 of the
    # pre-existing rows collided with generated ones before this.
    doc0 = json.loads(SIGNS.read_text(encoding="utf-8"))
    kept: list[tuple[float, float]] = []
    cells: dict[tuple[int, int], list[int]] = collections.defaultdict(list)
    for x in doc0["signs"]:
        if x.get("kind") != "one_way" or x.get("source") == SOURCE:
            continue
        lat, lng = float(x["lat"]), float(x["lng"])
        cells[(int(lng / 0.001), int(lat / 0.001))].append(len(kept))
        kept.append((lat, lng))
    seeded = len(kept)
    print(f"seeded dedup with {seeded} existing one_way rows")
    for entry, exit_, street in kept_runs:
        for pt in (entry, exit_):
            lat, lng = float(pt[0]), float(pt[1])
            cx, cy = int(lng / 0.001), int(lat / 0.001)
            near = False
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for k in cells.get((cx + dx, cy + dy), ()):
                        # `<=`, not `<`: the gate's rule is "no same-kind pair
                        # WITHIN 80 m", so a pair at exactly 80.0 m is a
                        # violation. `<` left 6 pairs at 80 m.
                        if metres((lat, lng), kept[k]) <= DEDUP_M:
                            near = True
                            break
                    if near:
                        break
                if near:
                    break
            if near:
                continue
            cells[(cx, cy)].append(len(kept))
            kept.append((lat, lng))
    new_rows = len(kept) - seeded
    print(f"after {DEDUP_M:.0f} m dedup: {new_rows:,} NEW sign rows "
          f"({new_rows / max(one_way, 1):.3f} per one-way segment)")
    if new_rows > args.max_rows:
        print(f"REFUSING: {new_rows:,} > --max-rows {args.max_rows:,}")
        return 2

    if not args.write:
        print("\n(dry run — nothing written; pass --write)")
        return 0

    doc = doc0
    rows = doc["signs"]
    # Drop the rows a previous run of THIS tool wrote (source marker), keep the
    # hand/Waze-comment ones so a rebuild is idempotent and loses nothing else.
    before = len(rows)
    rows = [x for x in rows if x.get("source") != SOURCE]
    removed = before - len(rows)
    added = 0
    for lat, lng in kept[seeded:]:
        rows.append({"name": NAME, "lat": round(lat, 5), "lng": round(lng, 5),
                     "kind": "one_way", "source": SOURCE})
        added += 1
    doc["signs"] = rows
    doc["generated"] = (f"{time.strftime('%Y-%m-%d')} (+{added:,} one_way signs "
                        f"from the WME segment one-way data)")
    backup = SIGNS.with_suffix(f".json.bak-oneway-{int(time.time())}")
    shutil.copy2(SIGNS, backup)
    SIGNS.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    print(f"\nwrote {SIGNS}")
    print(f"  rows {before:,} -> {len(rows):,}  (removed {removed:,} old "
          f"'{SOURCE}' rows, added {added:,})")
    print(f"  backup: {backup.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
