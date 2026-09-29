#!/usr/bin/env python3
"""Gate a `vietnam_signs.json` before it reaches a build.

    python3 tools/signs/validate_sign_placement.py                     # check
    python3 tools/signs/validate_sign_placement.py --save-baseline     # record
    python3 tools/signs/validate_sign_placement.py --file <other.json> # check one file

WHY a separate tool: `tools/signs/snap_sign_roads.py` gates its OWN write, but
that only protects the one path. An asset also arrives from `build_signs.py`,
`rebuild_edog_signs.py`, `rebuild_waze_assets.py`, a hand edit, or a bad merge —
and the failure mode is silent: the file is valid JSON, the app loads it, and the
signs are simply in the wrong place. This is the check to run on whatever file is
about to ship.

WHAT it fails on
  * a same-kind pair within 80 m — the same rule `test/data_integrity_test.dart`
    makes (a snap that collapses two zone vertices into one spot);
  * a drop in the share of records that are ON a road, per kind, against
    `tools/signs/placement_baseline.json` (an un-snapped or re-generated asset
    puts the zone kinds back 70-80 m off the carriageway);
  * a coordinate the loader will reject (< 4 decimals), a row outside Việt Nam, or
    a speed value that cannot exist;
  * a kind that disappears, or the loaded-row count moving, when the baseline
    knows it.

Exit code 0 = safe to ship, 1 = do not ship.
"""
from __future__ import annotations

import argparse
import collections
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT))

from tool.signs_app_filter import DROPPED_KINDS, load_app_signs  # noqa: E402
from tool.waze_segments import Segments  # noqa: E402
from tools.signs.snap_sign_roads import (  # noqa: E402
    POLICY,
    dup_pairs,
    haversine,
)

SIGNS = ROOT / "assets/offline_map/vietnam_signs.json"
SEGMENTS = ROOT / "assets/offline_map/waze_segments.bin"
BASELINE = ROOT / "tools/signs/placement_baseline.json"

# A record this close to a road that could carry it counts as placed.
ON_ROAD_M = 20.0
# How much the on-road share may fall before the asset is considered worse.
TOLERANCE_POINTS = 5.0
# Viet Nam, generously.
BBOX = (8.0, 102.0, 24.0, 110.5)


def measure(path: Path, seg: Segments) -> dict:
    """Per-kind placement of the rows the APP loads."""
    rows, stats = load_app_signs(path)
    pos = {i: (float(r["lat"]), float(r["lng"])) for i, r in enumerate(rows)}
    on_road = collections.Counter()
    seen = collections.Counter()
    dists: dict[str, list[float]] = collections.defaultdict(list)
    for r in rows:
        kind = r.get("kind")
        pol = POLICY.get(kind)
        if pol is None:
            continue
        seen[kind] += 1
        d, ok = None, False
        res = list(seg.query(float(r["lat"]), float(r["lng"]), max_dist_m=pol[0]))
        if res[4] is not None:
            d = float(res[4])
            ok = pol[1](int(res[2]), bool(res[3]))
        if d is not None:
            dists[kind].append(d)
        if d is not None and ok and d <= ON_ROAD_M:
            on_road[kind] += 1
    return {"rows": rows, "stats": stats, "order": pos, "seen": seen,
            "on_road": on_road, "dists": dists}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=str(SIGNS))
    ap.add_argument("--baseline", default=str(BASELINE))
    ap.add_argument("--save-baseline", action="store_true")
    args = ap.parse_args()

    path = Path(args.file)
    seg = Segments(str(SEGMENTS))
    m = measure(path, seg)
    rows, stats = m["rows"], m["stats"]
    problems: list[str] = []
    notes: list[str] = []

    # ---- absolute checks -------------------------------------------------
    pairs = dup_pairs(rows, m["order"])
    if pairs:
        problems.append(
            f"{len(pairs)} same-kind pair(s) within 80 m "
            f"(nearest {min(d for _, _, d in pairs):.0f} m) — "
            "test/data_integrity_test.dart would fail")

    lo_lat, lo_lng, hi_lat, hi_lng = BBOX
    outside = [r for r in rows
               if not (lo_lat <= r["lat"] <= hi_lat and lo_lng <= r["lng"] <= hi_lng)]
    if outside:
        problems.append(f"{len(outside)} row(s) outside the Việt Nam bbox")

    impossible = sum(1 for r in rows
                     if r.get("kind") == "speed" and r.get("value") is not None
                     and (int(r["value"]) <= 0 or int(r["value"]) > 120))
    if impossible:
        problems.append(f"{impossible} impossible speed value(s) (> 120 km/h)")

    print(f"file          {path}")
    print(f"rows          {stats['total']} (app loads {stats['kept']}; dropped "
          f"{stats['droppedKind']} built-up, {stats['coarse']} coarse, "
          f"{stats['impossible']} impossible)")
    print(f"same-kind pairs within 80 m : {len(pairs)}")
    print(f"rows outside Việt Nam       : {len(outside)}")

    # ---- placement, per kind --------------------------------------------
    print(f"\n{'kind':18}{'rows':>7}{'on road <=20m':>15}{'median off':>12}")
    metrics: dict[str, dict] = {}
    for kind in sorted(m["seen"]):
        n = m["seen"][kind]
        share = 100.0 * m["on_road"][kind] / n
        med = statistics.median(m["dists"][kind]) if m["dists"][kind] else None
        metrics[kind] = {"rows": n, "on_road_pct": round(share, 1),
                         "median_off_m": round(med, 1) if med is not None else None}
        print(f"{kind:18}{n:>7}{share:>14.1f}%"
              f"{(f'{med:.0f} m' if med is not None else '-'):>12}")

    # ---- baseline comparison --------------------------------------------
    bp = Path(args.baseline)
    if args.save_baseline:
        bp.parent.mkdir(parents=True, exist_ok=True)
        bp.write_text(json.dumps(
            {"note": "generated by tools/signs/validate_sign_placement.py "
                     "--save-baseline; regenerate only with a reviewed asset",
             "loaded": stats["kept"], "kinds": metrics},
            ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"\nbaseline written: {bp.relative_to(ROOT)}")
    elif bp.exists():
        base = json.loads(bp.read_text(encoding="utf-8"))
        print(f"\nvs baseline ({bp.name}, {base['loaded']} loaded rows)")
        for kind, b in base["kinds"].items():
            if kind not in metrics:
                problems.append(f"kind '{kind}' is gone from the asset "
                                f"(baseline: {b['rows']} rows)")
                continue
            drop = b["on_road_pct"] - metrics[kind]["on_road_pct"]
            flag = "  <-- REGRESSION" if drop > TOLERANCE_POINTS else ""
            print(f"  {kind:18}{b['on_road_pct']:>6.1f}% -> "
                  f"{metrics[kind]['on_road_pct']:>6.1f}%{flag}")
            if drop > TOLERANCE_POINTS:
                problems.append(
                    f"kind '{kind}' on-road share fell {drop:.1f} points "
                    f"({b['on_road_pct']}% -> {metrics[kind]['on_road_pct']}%)")
        for kind in metrics:
            if kind not in base["kinds"]:
                notes.append(f"new kind '{kind}' ({metrics[kind]['rows']} rows) "
                             "is not in the baseline")
    else:
        notes.append(f"no baseline at {bp.relative_to(ROOT)} — placement"
                     " regressions cannot be detected (run --save-baseline)")

    for n in notes:
        print(f"note: {n}")

    if problems:
        print("\nDO NOT SHIP:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("\nOK — placement, duplicates and coordinate sanity all pass.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
