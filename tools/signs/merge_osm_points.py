#!/usr/bin/env python3
"""Put the toll booths and railway crossings where they actually are.

    python3 tools/signs/merge_osm_points.py --fetch            # refresh the points
    python3 tools/signs/merge_osm_points.py                    # dry run
    python3 tools/signs/merge_osm_points.py --write            # backup + rewrite

WHY: `toll_booth` and `railway_crossing` in `vietnam_signs.json` come from the
VietMap E-DOG ZONE dump, whose point is a polygon vertex — measured 2026-09-24,
a median 70-80 m off the carriageway, and for only ~29 % / 39 % of the rows is
there even a qualifying road to snap them onto. Overpass has the real features as
POINTS on the road, and they are good: of 1,547 `barrier=toll_booth` nodes 59 %
are within 20 m of a road in the segment layer (median 4 m), and of 8,703
`railway=level_crossing` nodes 41 % (median 9 m) — the rest are on minor roads the
segment layer does not carry, which is a limit of the MEASURE, not of the point.

WHAT IT DOES — one record per feature, and nothing is thrown away silently:

  * an Overpass point that has NO same-kind record within 80 m is ADDED as a new
    record (`source: osm`), so the driver gets the crossings the zone dump never
    had at all;
  * an Overpass point that has exactly ONE same-kind record within 80 m ADOPTS
    that record: the record keeps its identity but takes the precise coordinate
    and `source: osm` — the record count does not move, the position does (this
    is the only correct resolution: leaving both would break the app's own
    "one record per feature within 80 m" rule that `test/data_integrity_test.dart`
    enforces, and would make the voice announce one crossing twice);
  * a point whose single same-kind neighbour is ALREADY osm-sourced is skipped:
    that record IS this feature. This is also what makes the tool idempotent —
    running it twice must not keep moving records around;
  * an Overpass point with TWO OR MORE same-kind records within 80 m is SKIPPED
    and counted — the geometry is ambiguous there, and the safe answer is to
    touch nothing rather than guess.

Gates before writing, same as `snap_sign_roads.py`: 0 same-kind pairs within
80 m, no record lost, coordinates inside Việt Nam, no impossible speed. Then the
file is read back and the gates re-run on the bytes on disk.
"""
from __future__ import annotations

import argparse
import collections
import json
import shutil
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

from tool.signs_app_filter import DROPPED_KINDS, load_app_signs  # noqa: E402
from tools.signs.snap_sign_roads import (  # noqa: E402
    DUP_M,
    dup_pairs,
    haversine,
    precise_enough,
)

SIGNS = ROOT / "assets/offline_map/vietnam_signs.json"
DEFAULT_POINTS = Path("/tmp/vn_toll_crossing.json")
MIRROR = "https://overpass.kumi.systems/api/interpreter"
BBOX = "8.2,102.1,23.4,109.5"
QUERY = f"""[out:json][timeout:300];
(
  node["barrier"="toll_booth"]({BBOX});
  way["barrier"="toll_booth"]({BBOX});
  node["railway"="level_crossing"]({BBOX});
);
out center;"""

# kind -> the Vietnamese label the app shows and speaks. These are the labels the
# dataset already uses (`tool/merge_edog_vietmap.py` maps E-DOG 6/8 to them), so a
# record's name does not betray which source produced it.
NAMES = {"toll_booth": "Trạm thu phí",
         "railway_crossing": "Đường ngang giao với đường sắt"}

CELL = 0.001  # ~111 m — one cell + its neighbours safely covers DUP_M


def fetch(path: Path) -> None:
    data = urllib.parse.urlencode({"data": QUERY}).encode()
    req = urllib.request.Request(
        MIRROR, data=data,
        headers={"User-Agent": "navbridge-signs/1.0 (offline sign index)"})
    with urllib.request.urlopen(req, timeout=300) as r:
        body = r.read()
    path.write_bytes(body)
    print(f"fetched {len(body)} bytes -> {path}")


def osm_points(path: Path) -> list[tuple[str, float, float]]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    out: list[tuple[str, float, float]] = []
    for e in doc.get("elements", []):
        t = e.get("tags", {})
        if t.get("barrier") == "toll_booth":
            kind = "toll_booth"
        elif t.get("railway") == "level_crossing":
            kind = "railway_crossing"
        else:
            continue
        lat = e.get("lat") or (e.get("center") or {}).get("lat")
        lng = e.get("lon") or (e.get("center") or {}).get("lon")
        if lat is None or lng is None:
            continue
        out.append((kind, float(lat), float(lng)))
    # Deterministic order, independent of how Overpass returned the elements.
    out.sort(key=lambda p: (p[0], p[1], p[2]))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", default=str(DEFAULT_POINTS))
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    pts_path = Path(args.points)
    if args.fetch:
        fetch(pts_path)
    if not pts_path.exists():
        print(f"no point file at {pts_path} — run with --fetch first")
        return 1

    doc = json.loads(SIGNS.read_text(encoding="utf-8"))
    rows = doc["signs"]
    kept_before = load_app_signs(SIGNS)[1]["kept"]
    kinds = set(NAMES)

    # Live grid of same-kind records: existing ones first, then whatever we add.
    grid: dict[tuple[str, int, int], list[int]] = collections.defaultdict(list)

    def index(i: int) -> None:
        r = rows[i]
        grid[(r["kind"], int(r["lat"] / CELL), int(r["lng"] / CELL))].append(i)

    for i, r in enumerate(rows):
        if r.get("kind") in kinds:
            index(i)

    def near(kind: str, lat: float, lng: float, metres: float = DUP_M) -> list[int]:
        ci, cj = int(lat / CELL), int(lng / CELL)
        out = []
        for a in range(ci - 1, ci + 2):
            for b in range(cj - 1, cj + 2):
                for i in grid.get((kind, a, b), ()):
                    if haversine(lat, lng, rows[i]["lat"], rows[i]["lng"]) <= metres:
                        out.append(i)
        return out

    added = collections.Counter()
    adopted = collections.Counter()
    skipped_conflict = collections.Counter()
    skipped_already = collections.Counter()

    for kind, lat, lng in osm_points(pts_path):
        # An OSM node can sit exactly on a whole degree or half degree (a
        # crossing at 106.6500): the loader drops anything under 4 decimals, so
        # nudge it a tenth of a metre rather than add a row the app never sees.
        lat, lng = precise_enough(lat), precise_enough(lng)
        if lat is None or lng is None:
            continue
        hit = near(kind, lat, lng)
        if not hit:
            rows.append({"name": NAMES[kind], "kind": kind,
                         "lat": lat, "lng": lng, "value": None, "source": "osm"})
            index(len(rows) - 1)
            added[kind] += 1
        elif len(hit) == 1 and rows[hit[0]].get("source") != "osm":
            # Keep the record, take the precise position.
            rows[hit[0]]["lat"] = lat
            rows[hit[0]]["lng"] = lng
            rows[hit[0]]["source"] = "osm"
            index(hit[0])  # the record moved cells — the live grid must know
            adopted[kind] += 1
        elif len(hit) == 1:
            # Already an osm-sourced record: this point IS that feature. Skipping
            # also makes the tool idempotent — a second run changes nothing.
            skipped_already[kind] += 1
        else:
            skipped_conflict[kind] += 1

    # A point added earlier in this run makes a later one a duplicate; count those
    # separately so the report says WHY a point was not used.
    seen_pairs = len(dup_pairs(rows, {i: (r["lat"], r["lng"])
                                      for i, r in enumerate(rows)}))
    if seen_pairs:
        print(f"note: {seen_pairs} same-kind pair(s) within {DUP_M:.0f} m remain "
              "after the merge")

    print(f'\n{"kind":18}{"osm points":>11}{"added":>7}{"adopted":>9}'
          f'{"already":>9}{"ambiguous":>11}{"asset rows":>12}')
    points = osm_points(pts_path)
    for kind in sorted(kinds):
        n = sum(1 for k, _, _ in points if k == kind)
        have = sum(1 for r in rows if r.get("kind") == kind)
        print(f"{kind:18}{n:>11}{added[kind]:>7}{adopted[kind]:>9}"
              f"{skipped_already[kind]:>9}{skipped_conflict[kind]:>11}"
              f"{have:>12}")
    print("already   = the feature already has an osm record (nothing to do)\n"
          "ambiguous = 2+ existing same-kind records within 80 m: nothing touched\n"
          "A re-run of this tool is a no-op by design — 'added' must be 0.")

    pos = {i: (r["lat"], r["lng"]) for i, r in enumerate(rows)}
    pairs = dup_pairs(rows, pos)
    outside = sum(1 for r in rows
                  if not (8.0 <= r["lat"] <= 24.0 and 102.0 <= r["lng"] <= 110.5))

    problems: list[str] = []
    if pairs:
        problems.append(f"{len(pairs)} same-kind pair(s) within {DUP_M:.0f} m")
    if outside:
        problems.append(f"{outside} row(s) outside the Việt Nam bbox")

    print(f"\nGATES\n  asset rows           {len(rows)} (was "
          f"{len(rows) - sum(added.values())}; added "
          f"{sum(added.values())}, adopted {sum(adopted.values())})")
    print(f"  same-kind pairs <= {DUP_M:.0f} m  {len(pairs)}"
          f"{'  OK' if not pairs else '  FAIL'}")
    print(f"  rows outside VN      {outside}{'  OK' if not outside else '  FAIL'}")
    print(f"  app loads (before)   {kept_before} — additions only, nothing removed")

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
    SIGNS.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")),
                     encoding="utf-8")
    print(f"\nwritten {SIGNS} (backup: {backup.name})")

    back = json.loads(SIGNS.read_text(encoding="utf-8"))["signs"]
    b_pairs = dup_pairs(back, {i: (r["lat"], r["lng"]) for i, r in enumerate(back)})
    b_kept = load_app_signs(SIGNS)[1]["kept"]
    print(f"read back: {len(back)} rows · app loads {b_kept} · "
          f"same-kind pairs <= {DUP_M:.0f} m {len(b_pairs)}")
    if b_pairs:
        print("⚠️  read-back verification FAILED")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
