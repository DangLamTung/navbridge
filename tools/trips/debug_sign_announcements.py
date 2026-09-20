#!/usr/bin/env python3
"""Find WRONG road-sign announcements by matching what the app announced against
the real sign data at the same coordinates, across every recorded trip.

Motivation: while driving, a route that turns right showed "cấm rẽ trái", and
"cấm quay đầu" looked wrong. The Waze type->kind mapping and the PNG artwork were
both verified correct separately, so the remaining suspects are in the app's
sign SELECTION / ANNOUNCEMENT path. This script finds the actual bad cases in
recorded trips instead of guessing:

  for each announcement with kind == 'sign'
      -> find the nearest turn-restriction sign in vietnam_signs.json
      -> read the direction implied by the ANNOUNCED TEXT (trái / phải / quay đầu)
      -> read the direction of the DATA SIGN (kind)
      -> flag when they disagree

It also reports announcements whose text names a direction but which have NO
turn sign anywhere nearby (announced from thin air / wrong layer).

Usage:
    python3 tools/trips/debug_sign_announcements.py [--near-m 80] [--dir DIR]
"""
import argparse
import glob
import json
import math
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIGNS_JSON = os.path.join(ROOT, "assets", "offline_map", "vietnam_signs.json")

TURN_KINDS = {
    "no_left_turn", "no_right_turn", "no_u_turn",
    "no_left_uturn", "no_right_uturn",
}
KIND_DIRS = {
    # A combined sign (P.123a / P.124a) forbids a turn AND the u-turn, so an
    # announcement naming either one is legitimate.
    "no_left_turn": {"LEFT"}, "no_right_turn": {"RIGHT"}, "no_u_turn": {"UTURN"},
    "no_left_uturn": {"LEFT", "UTURN"}, "no_right_uturn": {"RIGHT", "UTURN"},
}

# 'phía trước 178 mét' / 'sau 50 m' — the sign is AHEAD of the car, so the
# announcement position is NOT the sign position. Match on this distance.
DIST_RE = re.compile(r"(\d+)\s*(?:m\u00e9t|m)\b")


def hav(a_lat, a_lng, b_lat, b_lng):
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lng - a_lng)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(x))


def text_dirs(t):
    """Directions named in an announcement (a sentence can name two)."""
    t = (t or "").lower()
    out = set()
    if re.search(r"rẽ\s*trái|cấm rẽ trái|quẹo trái", t):
        out.add("LEFT")
    if re.search(r"rẽ\s*phải|cấm rẽ phải|quẹo phải", t):
        out.add("RIGHT")
    if "quay đầu" in t:
        out.add("UTURN")
    return out


def load_turn_signs():
    doc = json.load(open(SIGNS_JSON))
    signs = doc["signs"] if isinstance(doc, dict) else doc
    out = []
    for s in signs:
        if s.get("kind") in TURN_KINDS:
            out.append((float(s["lat"]), float(s["lng"]), s["kind"],
                        s.get("name"), s.get("source")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--near-m", type=float, default=80.0)
    ap.add_argument("--dir", action="append", default=None,
                    help="directory of trips (repeatable). Default: docs/trips + docs/trips/device")
    ap.add_argument("--examples", type=int, default=25)
    args = ap.parse_args()

    signs = load_turn_signs()
    print(f"turn-restriction signs in asset: {len(signs)}  "
          f"{dict(Counter(k for _, _, k, _, _ in signs))}")
    cell = 0.003
    grid = {}
    for i, s in enumerate(signs):
        grid.setdefault((int(s[0] / cell), int(s[1] / cell)), []).append(i)

    dirs = args.dir or [os.path.join(ROOT, "docs", "trips"),
                        os.path.join(ROOT, "docs", "trips", "device")]
    files = []
    for d in dirs:
        files += glob.glob(os.path.join(d, "*.json"))
    files = sorted(set(files), key=os.path.basename)
    print(f"trips scanned: {len(files)}\n")

    tot_sign_ann = 0
    no_neighbour = 0
    agree = 0
    mism = []
    for path in files:
        try:
            doc = json.load(open(path))
        except (OSError, ValueError):
            continue
        anns = doc.get("announcements") or []
        for a in anns:
            if (a.get("kind") or "") != "sign":
                continue
            tot_sign_ann += 1
            lat, lng = a.get("lat"), a.get("lng")
            if lat is None or lng is None:
                continue
            want = text_dirs(a.get("text"))
            if not want:
                continue
            dm = DIST_RE.search((a.get("text") or "").lower())
            announced_d = float(dm.group(1)) if dm else None
            # The sign sits ahead of the car at roughly the announced distance.
            # If the text gives no distance ('sắp tới' = imminent) treat it as
            # close-by.
            if announced_d is None:
                lo, hi = 0.0, 60.0
            else:
                lo, hi = max(0.0, announced_d - 40.0), announced_d + 60.0
            cands = []
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for i in grid.get((int(lat / cell) + dx, int(lng / cell) + dy), ()):
                        d = hav(lat, lng, signs[i][0], signs[i][1])
                        if lo <= d <= hi:
                            cands.append((d, i))
            if not cands:
                no_neighbour += 1
                continue
            bestd, best = min(cands)
            got = KIND_DIRS.get(signs[best][2], set())
            if want & got:
                agree += 1
            else:
                mism.append({
                    "trip": os.path.basename(path),
                    "time": a.get("time"),
                    "text": a.get("text"),
                    "announced": "/".join(sorted(want)),
                    "announced_d": announced_d,
                    "sign_kind": signs[best][2],
                    "sign_name": signs[best][3],
                    "sign_source": signs[best][4],
                    "dist_m": round(bestd, 1),
                })

    print(f"sign announcements total     : {tot_sign_ann}")
    print(f"  no turn sign at the announced distance: {no_neighbour}")
    print(f"  matched a turn sign         : {agree + len(mism)}")
    print(f"    direction AGREES          : {agree}")
    print(f"    direction CONFLICTS       : {len(mism)}")
    print()
    if mism:
        c = Counter(f"{m['announced']} announced vs {m['sign_kind']}" for m in mism)
        print("conflict patterns:")
        for k, n in c.most_common():
            print(f"   {n:4d}  {k}")
        print()
        print(f"conflicts (nearest first), * = announced 100 m+ ahead:")
        for m in sorted(mism, key=lambda x: x["dist_m"])[:args.examples]:
            far = "*" if (m["announced_d"] or 0) >= 100 else " "
            print(f"  {far}{m['dist_m']:6.1f} m  {m['sign_kind']:<16} {m['sign_name']}")
            print(f"          announced: {m['announced']} (text said {m['announced_d']}) @ {m['time']}")
            print(f"          text: {m['text'][:110]}")
            print(f"          trip: {m['trip']}")
    return 1 if mism else 0


if __name__ == "__main__":
    sys.exit(main())
