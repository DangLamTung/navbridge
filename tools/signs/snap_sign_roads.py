#!/usr/bin/env python3
"""Snap misplaced sign records onto the road they belong to.

    python3 tools/signs/snap_sign_roads.py            # dry run, prints the audit
    python3 tools/signs/snap_sign_roads.py --write    # backup + rewrite

WHY (measured 2026-09-24, `tool/sign_placement_audit.py` on the rows the app
loads): every kind that comes from the VietMap E-DOG point dump sits a median
70-80 m off the nearest road — `toll_booth` 76 m, `no_passing` 76 m, `tunnel`
69 m, `railway_crossing` 73 m, `slow_down` 74 m — while every point-sourced kind
is ON the road (`signal` 2 m, `speed` 6-9 m). The E-DOG point for those kinds is
a zone/station reference, not a roadside post, so the marker lands in a field
and the voice would announce a distance from the wrong place.

WHAT THIS DOES: for those kinds only, project the record onto the nearest road
that COULD carry such a feature, and move the coordinate to that projection.
Records are never deleted — they carry real information (a toll station exists
there), they are just placed on the road they describe. A record with no
qualifying road nearby is left exactly as it is, so nothing is invented.

Per-kind qualification (a toll booth cannot be on a residential lane):

  toll_booth, no_passing, no_passing_end   a highway class (freeway / ramp /
                                           major / minor highway) — for the
                                           overtaking ban also a primary street
                                           with a separator, since a ban only
                                           means something where overtaking is
                                           allowed in the first place
  tunnel, railway_crossing, slow_down      any road: a level crossing or a
                                           tunnel legitimately sits on a small
                                           road, so class is not a criterion

The class numbers come from the Waze roadType the segment layer carries, labelled
by the limits the layer itself shows (3 = 90 km/h freeway, 6 = 80 major highway,
7 = 60 minor highway, 1/2 = 50 city street) — see `--per-kind` output of
`tool/sign_placement_audit.py --by-class`.

WHAT IT REFUSES TO DO (learned the hard way, 2026-09-24):

  * never delete or merge a record. The first version snapped blind and pulled 22
    same-kind pairs together that the source had left 102-188 m apart; those pairs
    are ZONE vertices (one `no_passing` row even shared its coordinate with a
    `toll_booth` row), so a "dedup" would have thrown away real data. A record that
    would land within 80 m of its same-kind neighbour is now FROZEN at its source
    coordinate instead.
  * never write a coordinate the loader will throw away (`precise_enough`).
  * never write at all unless the gates pass: loaded-row count unchanged AND 0
    same-kind pairs within 80 m over the whole file — the same check
    `test/data_integrity_test.dart` makes. The file is then read back and the
    gates are re-run on the bytes on disk.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

from tool.signs_app_filter import (  # noqa: E402
    DROPPED_KINDS,
    coords_usable,
    is_impossible_speed,
)
from tool.waze_segments import Segments  # noqa: E402

SIGNS = ROOT / "assets/offline_map/vietnam_signs.json"
SEGMENTS = ROOT / "assets/offline_map/waze_segments.bin"

# Waze roadType, labelled from the layer's own posted limits.
BIG_ROADS = {3, 4, 6, 7}  # freeway, ramp, major highway, minor highway
PRIMARY = 2

# kind -> (max distance to consider, predicate on (class, separator))
POLICY = {
    "toll_booth": (120.0, lambda cls, sep: cls in BIG_ROADS),
    "no_passing": (120.0, lambda cls, sep: cls in BIG_ROADS or (cls == PRIMARY and sep)),
    "no_passing_end": (120.0, lambda cls, sep: cls in BIG_ROADS or (cls == PRIMARY and sep)),
    "tunnel": (60.0, lambda cls, sep: True),
    "railway_crossing": (60.0, lambda cls, sep: True),
    "slow_down": (60.0, lambda cls, sep: True),
}

M_PER_DEG_LAT = 111320.0


def decimals(value: float) -> int:
    text = repr(float(value))
    if "e-" in text:
        return int(text.split("e-")[1])
    return len(text.split(".")[1].rstrip("0")) if "." in text else 0


def precise_enough(value: float) -> float | None:
    """A coordinate the app will still load.

    `offline_road_signs.dart` drops any row with fewer than 4 decimals per
    coordinate (it is how a ~111 m grid snap is caught), and a projection can
    land on a ROUND value — a road that runs along a whole/half degree line
    projects a sign onto 106.65, which parses to 2 decimals and would be thrown
    away. Snapping a record must never cost it its place in the database, so a
    value that comes out too round gets nudged by 0.1 m (imperceptible for a
    sign) until it is safe, and if that fails the record is left alone.
    """
    for step in range(6):
        v = value + step * 1e-6
        if decimals(v) >= 4:
            return v
    return None


def nearest_point_on(points: list[tuple[float, float]],
                     lat: float, lng: float) -> tuple[float, float, float]:
    """(snapped lat, snapped lng, distance m) to the polyline [points]."""
    m_lng = M_PER_DEG_LAT * math.cos(math.radians(lat))
    px, py = lng * m_lng, lat * M_PER_DEG_LAT
    best_d = float("inf")
    best = (lat, lng)
    for i in range(len(points) - 1):
        ax, ay = points[i][1] * m_lng, points[i][0] * M_PER_DEG_LAT
        bx, by = points[i + 1][1] * m_lng, points[i + 1][0] * M_PER_DEG_LAT
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        if l2 <= 1e-9:
            continue
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
        cx, cy = ax + t * dx, ay + t * dy
        d = math.hypot(px - cx, py - cy)
        if d < best_d:
            best_d = d
            best = (cy / M_PER_DEG_LAT, cx / m_lng)
    return best[0], best[1], best_d


DUP_M = 80.0


def haversine(a_lat: float, a_lng: float, b_lat: float, b_lng: float) -> float:
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def dup_pairs(rows: list[dict], pos: dict[int, tuple[float, float]],
              metres: float = DUP_M) -> list[tuple[int, int, float]]:
    """Same-kind pairs closer than [metres] — the same scan
    `test/data_integrity_test.dart` runs over the whole file (lat-sorted window,
    no app filter).

    ⭐ This is the gate the 2026-09-24 write slipped past. The first version of
    this tool snapped every record to the globally nearest point of the nearest
    road, which pulled 22 same-kind pairs together that the SOURCE had left
    102-188 m apart (median 113 m). Those pairs are ZONE vertices, not duplicates
    — one `no_passing` row even shared its coordinate with a `toll_booth` row —
    so the fix is to FREEZE the offending record at its source coordinate, never
    to merge or delete it.
    """
    order = sorted(range(len(rows)), key=lambda i: pos[i][0])
    out: list[tuple[int, int, float]] = []
    for x in range(len(order)):
        i = order[x]
        for y in range(x + 1, len(order)):
            j = order[y]
            if (pos[j][0] - pos[i][0]) * M_PER_DEG_LAT > metres:
                break
            if rows[j].get("kind") != rows[i].get("kind"):
                continue
            d = haversine(pos[i][0], pos[i][1], pos[j][0], pos[j][1])
            if d <= metres:
                out.append((i, j, d))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--limit", type=int, default=0,
                    help="only process the first N rows of each kind (debug)")
    args = ap.parse_args()

    doc = json.loads(SIGNS.read_text(encoding="utf-8"))
    rows = doc["signs"]

    def app_keeps(row: dict) -> bool:
        """Mirror of the Dart loader's row filter — see tool/signs_app_filter.py.

        Filtering HERE (rather than comparing against a second, separately parsed
        list) matters: re-reading the file builds new dicts, so an identity check
        silently matched nothing and the tool reported "0 rows" while looking
        perfectly reasonable.
        """
        return (
            row.get("kind") not in DROPPED_KINDS
            and not is_impossible_speed(row)
            and coords_usable(row)
        )

    kept_rows = [r for r in rows if app_keeps(r)]
    kept_before = len(kept_rows)
    print(f"asset {len(rows)} rows · app loads {len(kept_rows)} "
          f"(dropped {sum(1 for r in rows if r.get('kind') in DROPPED_KINDS)} "
          f"built-up, {sum(1 for r in rows if r.get('kind') not in DROPPED_KINDS and not is_impossible_speed(r) and not coords_usable(r))} coarse, "
          f"{sum(1 for r in rows if is_impossible_speed(r))} impossible)")

    seg = Segments(str(SEGMENTS))

    moved = collections.Counter()
    move_dist: dict[str, list[float]] = collections.defaultdict(list)
    no_road: collections.Counter = collections.Counter()
    still_off: collections.Counter = collections.Counter()
    frozen_dup: collections.Counter = collections.Counter()
    seen: collections.Counter = collections.Counter()

    originals: dict[int, tuple[float, float]] = {}
    eligible: list[int] = []
    for i, r in enumerate(rows):
        kind = r.get("kind")
        if POLICY.get(kind) is None or not app_keeps(r):
            continue  # app-dropped rows are not worth moving
        if args.limit and seen[kind] >= args.limit:
            continue
        seen[kind] += 1
        eligible.append(i)
        originals[i] = (float(r["lat"]), float(r["lng"]))

    cand: dict[int, tuple[float, float]] = {}
    for i in eligible:
        kind = rows[i]["kind"]
        max_d, qualifies = POLICY[kind]
        lat, lng = originals[i]
        res = list(seg.query(lat, lng, max_dist_m=max_d))
        dist = res[4]
        if dist is None:
            no_road[kind] += 1
            continue
        cls, sep, seg_id = int(res[2]), bool(res[3]), int(res[5])
        if not qualifies(cls, sep):
            # A road is there but it cannot carry this feature (a toll booth is
            # not on a residential lane): leave the record where the source put
            # it rather than inventing a location for it.
            continue
        slat, slng, _ = nearest_point_on(seg.pts[seg_id], lat, lng)
        slat, slng = precise_enough(slat), precise_enough(slng)
        if slat is None or slng is None:
            # Cannot write it without losing the row to the loader's precision
            # filter — leave it as it is.
            continue
        cand[i] = (slat, slng)

    # ---- collision guard: never let the snap merge two records ------------
    # A pair that ends up within DUP_M of its same-kind neighbour goes back to
    # its SOURCE coordinate. Iterating matters: returning one member can still
    # leave the other too close to a third record.
    frozen = {i for i in eligible if i not in cand}
    for _ in range(8):
        pos = {i: (cand[i] if (i in cand and i not in frozen)
                   else (float(rows[i]["lat"]), float(rows[i]["lng"])))
               for i in range(len(rows))}
        bad = dup_pairs(rows, pos)
        hit = {i for i, _, _ in bad} | {j for _, j, _ in bad}
        new = (hit & set(cand)) - frozen
        if not new:
            break
        frozen |= new

    pos = {i: (cand[i] if (i in cand and i not in frozen)
               else (float(rows[i]["lat"]), float(rows[i]["lng"])))
           for i in range(len(rows))}

    for i in eligible:
        kind = rows[i]["kind"]
        if i not in cand:
            pass
        elif i in frozen:
            frozen_dup[kind] += 1
        else:
            moved[kind] += 1
            move_dist[kind].append(
                haversine(originals[i][0], originals[i][1], pos[i][0], pos[i][1]))
        # Where does this record END UP relative to a road that could carry it?
        d, ok = None, False
        r2 = list(seg.query(pos[i][0], pos[i][1], max_dist_m=POLICY[kind][0]))
        if r2[4] is not None:
            d = float(r2[4])
            ok = POLICY[kind][1](int(r2[2]), bool(r2[3]))
        if d is None or not ok or d > 20:
            still_off[kind] += 1

    print(f'\n{"kind":18}{"rows":>7}{"snapped":>9}{"no road":>9}'
          f'{"kept put":>10}{"median move":>13}{"still >20m":>12}')
    for kind in POLICY:
        if not seen[kind]:
            continue
        moves = sorted(move_dist[kind])
        med = f"{moves[len(moves) // 2]:.0f} m" if moves else "-"
        print(f'{kind:18}{seen[kind]:>7}{moved[kind]:>9}{no_road[kind]:>9}'
              f'{frozen_dup[kind]:>10}{med:>13}{still_off[kind]:>12}')

    # ---- gates: refuse to write a file the app or the test would reject ----
    problems: list[str] = []
    pairs = dup_pairs(rows, pos)
    if pairs:
        problems.append(
            f"{len(pairs)} same-kind pair(s) within {DUP_M:.0f} m "
            f"(nearest {min(d for _, _, d in pairs):.0f} m) — "
            "test/data_integrity_test.dart would fail"
        )
    kept_after = sum(1 for i, r in enumerate(rows) if app_keeps(
        {"kind": r.get("kind"), "value": r.get("value"),
         "lat": pos[i][0], "lng": pos[i][1]}))
    if kept_after != kept_before:
        problems.append(f"loaded rows would go {kept_before} -> {kept_after}"
                        " (records may never be lost)")

    print("\nGATES")
    print(f"  loaded rows          {kept_before} -> {kept_after}"
          f"{'  OK' if kept_after == kept_before else '  FAIL'}")
    print(f"  same-kind pairs <= {DUP_M:.0f} m  {len(pairs)}"
          f"{'  OK' if not pairs else '  FAIL'}")
    print(f"  records frozen at source: {sum(frozen_dup.values())}"
          " (collision guard, nothing deleted)")

    if problems:
        print("\nREFUSING to write:")
        for p in problems:
            print(f"  - {p}")
        return 1
    if not args.write:
        print("\ndry run — nothing written. Re-run with --write.")
        return 0

    backup = SIGNS.with_suffix(f".json.bak-{int(time.time())}")
    shutil.copy2(SIGNS, backup)
    for i, p in pos.items():
        rows[i]["lat"], rows[i]["lng"] = p
    SIGNS.write_text(
        json.dumps(doc, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"\nwritten {SIGNS} (backup: {backup.name})")
    print(f"moved {sum(moved.values())} records onto their road")

    # Read the file back and re-run the gates on what is actually on disk — the
    # in-memory dicts are not evidence that the bytes are right.
    back = json.loads(SIGNS.read_text(encoding="utf-8"))["signs"]
    bpos = {i: (float(r["lat"]), float(r["lng"])) for i, r in enumerate(back)}
    b_pairs = dup_pairs(back, bpos)
    b_kept = sum(1 for r in back
                 if r.get("kind") not in DROPPED_KINDS
                 and not is_impossible_speed(r) and coords_usable(r))
    print(f"read back: {len(back)} rows · app loads {b_kept} · "
          f"same-kind pairs <= {DUP_M:.0f} m {len(b_pairs)}")
    if b_pairs or b_kept != kept_before:
        print("⚠️  read-back verification FAILED")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
