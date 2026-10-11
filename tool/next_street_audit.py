#!/usr/bin/env python3
"""Is the NEXT STREET's speed correct in the maneuver callout?

    python3 tool/next_street_audit.py --log /tmp/nb_fix22.log

The maneuver callout is "Đi trên Y, sau N mét, rẽ … vào X. Tốc độ tối đa K km/h."
It NAMES the street you turn into, so K must be the posted limit of a street the
sentence names — not of Y, the street under the car. Quoting Y was the bug the
driver reported on 2026-09-24.

`tool/announce_speed_audit.py` does this for DEVICE trips. This does the same
walk on a SIMULATOR log, using the trip fixture for the track, so "is it correct
now" can be answered for the build currently in the tree.

Method (same as the device audit):
  1. the callout logs the car's position and says how far the maneuver is (N)
     -> step N metres along the recorded track to the junction;
  2. every street name in the sentence is looked up in the Waze segment layer
     (the same reader the app uses) within 500 m of that junction;
  3. OK   = K equals a NAMED street's limit
     OLD  = K equals the limit under the car instead (the reported bug)
     MISS = neither
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import unicodedata

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from accuracy_report import TRIPS, cum_dist, parse, project  # noqa: E402
from announce_speed_audit import (  # noqa: E402
    Layer, ON, SAU, SPOKEN, STOP, fold, metres, parse_m,
)

INTO = re.compile(r"vào ([^,.]+)")


def step_along(geom, cum, start_lat, start_lng, n_m):
    """The point N metres further along the track from the car's position."""
    _off, along = project(geom, cum, start_lat, start_lng)
    target = along + n_m
    j = min(range(len(cum)), key=lambda k: abs(cum[k] - target))
    return geom[j]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    log = pathlib.Path(args.log)
    trips = parse(log)
    if not trips:
        sys.exit(f"ERROR: {log} parsed to 0 trips — check the trip markers.")

    layer = Layer()
    ok = old = miss = 0
    disc = disc_ok = 0
    above = []
    rows = []

    for tid, tr in trips.items():
        fix = TRIPS / f"{tid}.json"
        if not fix.exists():
            continue
        geom = json.loads(fix.read_text())["geometry"]
        cum = cum_dist(geom)
        for e in tr["events"]:
            if e["kind"] != "maneuver":
                continue
            txt = e["phrase"]
            sp, n = SPOKEN.search(txt), parse_m(txt)
            if not sp or not n:
                continue
            names = [m.strip() for m in INTO.findall(txt)
                     if fold(m.strip()) not in STOP]
            if not names:
                continue
            k = int(sp.group(1))
            mv = step_along(geom, cum, e["lat"], e["lng"], n)
            named = [(nm, layer.named(nm, mv)) for nm in names]
            hit = [nm for nm, h in named if h and h[0] == k]
            cur = layer.at((e["lat"], e["lng"]))
            if hit:
                ok += 1
                status = "OK  "
            elif cur[0] == k:
                old += 1
                status = "OLD "
            else:
                miss += 1
                status = "MISS"
            # Falsifiable rows: the sentence names a street whose limit differs
            # from the street under the car. Only these can be wrong.
            vals = [h[0] for _nm, h in named if h]
            if vals and cur[0] and min(vals) != cur[0]:
                disc += 1
                disc_ok += 1 if hit else 0
            named_txt = ", ".join(
                f"{nm[:18]}={'?' if not h else h[0]}" for nm, h in named)
            rows.append((tid, status, k, named_txt, cur))

    total = ok + old + miss
    if not total:
        print("no maneuver callout quoted a next-street limit")
        return 0

    print(f"{log.name}: {total} maneuver callouts quoting a next-street limit\n")
    print(f"{'trip':<9}{'':>5}{'spoken':>7}  {'names street':<40}{'on street':>18}")
    print("-" * 82)
    for tid, status, k, named_txt, cur in rows:
        print(f"{tid:<9}{status:>5}{k:>7}  {named_txt:<40}"
              f"{(cur[1] or '?')[:14]}={cur[0]:>3}")
    print("-" * 82)
    print(f"\n  quotes a street the sentence NAMES : {ok}/{total}"
          f"  ({ok / total * 100:.1f}%)")
    print(f"  quotes the street UNDER THE CAR    : {old}/{total}"
          f"  ({old / total * 100:.1f}%)   <- the 2026-09-24 bug")
    print(f"  neither                            : {miss}/{total}"
          f"  ({miss / total * 100:.1f}%)")
    if disc:
        print(f"\n  falsifiable rows (named street's limit differs from the one "
              f"under the car): {disc_ok}/{disc} correct")
    if above:
        print(f"\n  spoken ABOVE the named street's own limit: {len(above)} "
              f"<- {above[:6]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
