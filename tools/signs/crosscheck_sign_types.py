#!/usr/bin/env python3
"""Cross-check the Waze point-notice type -> Vietnamese sign mapping against
VietMap's sign data, which carries the actual QCVN sign names.

Why this exists
---------------
The nav map rendered the wrong prohibition sign on some routes (a right-turn
ban shown as "cấm rẽ trái", and "cấm quay đầu" wrong). The PNG artwork was
verified correct by `check_sign_art.py`, so the suspect is the mapping from
Waze's numeric `type` field to our sign kind.

`tools/signs/rebuild_waze_assets.py` claims:
    8,16 -> no_left_turn    (P.123)
    9,17 -> no_right_turn   (P.124)
    11,18 -> no_u_turn      (P.125)

This script tests that claim with evidence instead of trusting it: for every
Waze point of type T it looks up the nearest VietMap sign (which is explicitly
named "P.123 Cấm rẽ trái" / "P.124 Cấm rẽ phải" / "P.125 Cấm quay đầu") within
a small radius. If the Waze type really means "no left turn", the overwhelming
majority of its neighbours must be VietMap P.123; if the tally comes out
P.124, the mapping is swapped.

Usage:
    python3 tools/signs/crosscheck_sign_types.py [--max-m 60]
"""
import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIGNS_JSON = os.path.join(ROOT, "assets", "offline_map", "vietnam_signs.json")
WAZE_TSV = "/Users/tungdl/Documents/Eink/Decode_Waze/point_notices_v2.tsv"

# Waze types of interest -> the kind they are currently claimed to be
CLAIMED = {
    8: "no_left_turn",
    16: "no_left_turn",
    9: "no_right_turn",
    17: "no_right_turn",
    11: "no_u_turn",
    18: "no_u_turn",
}

# VietMap sign name -> our kind (from the authoritative "P.xxx" code in the name)
VIETMAP_NAME_KIND = {
    "P.123": "no_left_turn",
    "P.123a": "no_left_uturn",
    "P.124": "no_right_turn",
    "P.124a": "no_right_uturn",
    "P.125": "no_u_turn",
}


def hav(a_lat, a_lng, b_lat, b_lng):
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lng - a_lng)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(x))


def vietmap_kind(name, kind):
    """Resolve a VietMap sign to a kind using its P.xxx code when present."""
    for code in sorted(VIETMAP_NAME_KIND, key=len, reverse=True):
        if code in name:
            return VIETMAP_NAME_KIND[code]
    if kind in VIETMAP_NAME_KIND.values():
        return kind
    return None


def load_vietmap_signs():
    doc = json.load(open(SIGNS_JSON))
    signs = doc["signs"] if isinstance(doc, dict) else doc
    out = []
    for s in signs:
        if s.get("source") != "vietmap":
            continue
        k = vietmap_kind(s.get("name") or "", s.get("kind"))
        if k is None:
            continue
        out.append((float(s["lat"]), float(s["lng"]), k, s.get("name")))
    return out


def load_waze_points():
    pts = []
    with open(WAZE_TSV) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            p = line.split("\t")
            if len(p) < 4:
                continue
            try:
                t = int(p[1])
                lat, lng = float(p[2]), float(p[3])
            except ValueError:
                continue
            if t in CLAIMED:
                pts.append((t, lat, lng))
    return pts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-m", type=float, default=60.0,
                    help="match radius between a Waze point and a VietMap sign")
    args = ap.parse_args()

    vm = load_vietmap_signs()
    print(f"VietMap signs with a recognised QCVN code: {len(vm)}")
    print("  by kind:", dict(Counter(k for _, _, k, _ in vm)))

    waze = load_waze_points()
    print(f"Waze turn-restriction points (types {sorted(CLAIMED)}): {len(waze)}")

    # Grid the VietMap signs for a fast nearest lookup.
    cell = 0.002  # ~220 m
    grid = defaultdict(list)
    for i, (lat, lng, _k, _n) in enumerate(vm):
        grid[(int(lat / cell), int(lng / cell))].append(i)

    tally = defaultdict(Counter)
    examples = defaultdict(list)
    unmatched = Counter()
    for t, lat, lng in waze:
        best, bestd = None, 1e9
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((int(lat / cell) + dx, int(lng / cell) + dy), ()):
                    d = hav(lat, lng, vm[i][0], vm[i][1])
                    if d < bestd:
                        best, bestd = i, d
        if best is None or bestd > args.max_m:
            unmatched[t] += 1
            continue
        k = vm[best][2]
        tally[t][k] += 1
        if len(examples[t]) < 4:
            examples[t].append((vm[best][3], round(bestd, 1)))

    print()
    print(f"{'type':>5} {'claimed':<15} {'nearest VietMap kind (within '
          f'{args.max_m:.0f} m)':<40} verdict")
    print("-" * 96)
    bad = 0
    for t in sorted(CLAIMED):
        c = tally[t]
        total = sum(c.values())
        claim = CLAIMED[t]
        if not total:
            print(f"{t:>5} {claim:<15} (no VietMap neighbour found; "
                  f"unmatched={unmatched[t]})")
            continue
        top, topn = c.most_common(1)[0]
        pct = 100.0 * topn / total
        agree = top == claim
        if not agree:
            bad += 1
        dist = ", ".join(f"{k}={n}" for k, n in c.most_common())
        print(f"{t:>5} {claim:<15} {dist:<40} "
              f"{'AGREES' if agree else 'CONFLICT'} (top {top} {pct:.0f}% of {total})")
        for nm, d in examples[t]:
            print(f"        e.g. {d:6.1f} m -> {nm}")

    print()
    print("SUMMARY:",
          "mapping is consistent with VietMap ground truth" if not bad
          else f"{bad} Waze type(s) CONFLICT with VietMap ground truth")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
