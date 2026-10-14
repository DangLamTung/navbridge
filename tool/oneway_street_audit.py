#!/usr/bin/env python3
"""WHICH streets got a bogus "đường một chiều" sign?

Why this exists (2026-10-11): the one-way generator
(`tools/signs/build_oneway_signs.py`) trusted the per-SEGMENT one-way flag in
the WME crawl. But WME models a DIVIDED road as TWO one-way carriageways, so
every divided arterial looks one-way at segment level. Cộng Hòa and Trường Chinh
proved it. The emitted sign rows carry a generic `name` ("Đường một chiều") and
never the street, so the pack cannot be audited on its own - this re-derives it
from the app's own segment asset.

A street is a FALSE POSITIVE when it has at least one segment carrying BOTH
directions (fwd>0 and rev>0) - that is a two-way street - yet also has segments
that look one-way (exactly one of fwd/rev is 0). Those are the roads where a
"một chiều" sign must never appear.

Run: python3 tool/oneway_street_audit.py [--top N]
"""

from __future__ import annotations

import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SEGS = "assets/offline_map/waze_segments.bin"


def key(s: str) -> str:
    return " ".join((s or "").split()).lower()


def main() -> int:
    try:
        from waze_segments import Segments  # noqa: E402
    except Exception as e:  # pragma: no cover
        print(f"cannot import waze_segments.Segments: {e}")
        return 2

    seg = Segments(SEGS)
    n = seg.n_segs
    print(f"segments: {n:,}")

    both = collections.Counter()   # street has a both-ways segment -> TWO-WAY
    onewk = collections.Counter()  # street has a one-way-looking segment
    named = 0

    for i in range(n):
        try:
            name = key(seg.street(i))
        except Exception:
            name = ""
        if not name:
            continue
        named += 1
        f, r = seg.fwd[i], seg.rev[i]
        if f and r:
            both[name] += 1
        elif f or r:
            onewk[name] += 1

    print(f"named segments: {named:,}")
    print(f"distinct street names: {len(set(both) | set(onewk)):,}")
    print(f"names with a TWO-WAY segment: {len(both):,}")
    print()

    # A false positive = signed candidate (has one-way-looking segments) on a
    # street that also proves itself two-way somewhere.
    bad = [(s, onewk[s], both[s]) for s in onewk if s in both]
    bad.sort(key=lambda t: -t[1])

    total_oneway_looking = sum(onewk.values())
    print("=" * 78)
    print("FALSE-POSITIVE STREETS: look one-way in part, but are TWO-WAY in part")
    print(f"  {len(bad):,} street names, covering {sum(b[1] for b in bad):,} "
          f"of the {total_oneway_looking:,} one-way-looking segments")
    print("=" * 78)
    for s, o, b in bad[:40]:
        print(f"  {o:5d} one-way-ish / {b:5d} two-way   {s}")

    cleaned = [s for s in onewk if s not in both]
    print()
    print(f"plausibly REAL one-way streets (no two-way segment anywhere): "
          f"{len(cleaned):,}, {sum(onewk[s] for s in cleaned):,} segments")
    for s in sorted(cleaned, key=lambda x: -onewk[x])[:15]:
        print(f"  {onewk[s]:5d}   {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
