#!/usr/bin/env python3
"""Analyze GPS fix intervals in the recorded trip JSONs (Google Takeout format)
to see how fast/slow the GPS position updates were."""
import json
import statistics
from datetime import datetime

FILES = ["2026-08-08_200603_Chuyến_đi.json", "recorded_replay.json"]


def ts(p):
    t = p.get("timestampMs") or p.get("timestamp") or ""
    if not t:
        return None
    try:
        if isinstance(t, (int, float)):
            return t / 1000.0
        s = str(t)
        if s.isdigit():  # millisecond epoch string
            return int(s) / 1000.0
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def analyze(fn):
    with open(fn, encoding="utf-8") as f:
        d = json.load(f)
    locs = d["locations"]
    times = [t for t in (ts(p) for p in locs) if t]
    print(f"=== {fn}")
    print(f"  points: {len(locs)}  with ts: {len(times)}")
    if len(times) < 2:
        return
    times.sort()
    diffs = [b - a for a, b in zip(times[:-1], times[1:]) if 0 < (b - a) < 3600]
    if not diffs:
        print("  no usable gaps")
        return
    print(f"  duration: {(times[-1] - times[0]) / 60:.0f} min")
    print(
        f"  fix gaps (s): avg={statistics.mean(diffs):.1f} "
        f"median={statistics.median(diffs):.1f} "
        f"min={min(diffs):.1f} max={max(diffs):.1f}"
    )
    for th in (1.5, 5, 10, 30):
        print(f"  gaps > {th}s: {sum(1 for x in diffs if x > th)}")
    print(f"  sample: {json.dumps(locs[0], ensure_ascii=False)[:180]}")


for fn in FILES:
    analyze(fn)
