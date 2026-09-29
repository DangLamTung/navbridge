#!/usr/bin/env python3
"""Classify every test file: pure UNIT test, or FUNCTIONAL (real packs/fixtures)?

A unit test is deterministic and self-contained — it builds its own inputs and
never reads a bundled data pack, a recorded trip, or a fixture file. A
functional test exercises the app the way a driver does: it loads the shipped
packs, replays a real trip, or reads a fixture from disk (and therefore SKIPS
when the packs are stubbed in CI).

The rule is mechanical, so the split cannot drift with opinion:
  * a path literal pointing at a data file (test/…json, assets/…)
  * a pack loader (loadOffline*, TripReplay, rootBundle, File(...))
  * a known real-data fixture directory

Usage: python3 tool/classify_tests.py [--list]
"""
import glob
import os
import re
import sys

# Loaders that pull a bundled pack into the process.
PACK_LOADERS = [
    "loadOfflineSpeedLimits",
    "loadOfflineRoadSigns",
    "loadOfflineCameras",
    "loadOfflinePois",
    "loadOfflineTiles",
    "loadOfflineSearch",
    "speedLimitsPopulated",
    "signsPopulated",
    "camerasPopulated",
    "TripReplay",
    "tripReplay",
    "rootBundle",
    "TestAssetBundle",
    "loadTrip",
    "OfflineScanIsolate",
    "OfflinePoIs",
]

# A string literal that names a data file, not a URL or a km/h value.
DATA_PATH = re.compile(r"""['"](?!/)(?:test|assets)/[^'"]+\.(?:json|bin|csv|osm|pbf)['"]""")

# Reads a fixture from disk.
FILE_READ = re.compile(r"""File\(['"]""")

# A file the test creates itself (temp dir) is NOT a fixture: the test owns the
# bytes, so it stays deterministic and belongs on the unit line.
TEMP_FILE = re.compile(
    r"systemTemp|createTempSync|getTemporaryDirectory|Directory\.systemTemp")

# Real-data fixture directories (their presence means the test is functional).
FIXTURE_DIRS = ["test/data/", "test/assets/trips/", "assets/trips/",
                "assets/offline_map/", "assets/offline_map"]


def classify(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    reasons = []
    for name in PACK_LOADERS:
        if name in src:
            reasons.append(f"loads {name}")
    for m in set(DATA_PATH.findall(src)):
        reasons.append(f"data file {m}")
    if FILE_READ.search(src) and not TEMP_FILE.search(src):
        reasons.append("reads a file from disk")
    for d in FIXTURE_DIRS:
        if d in src:
            reasons.append(f"fixture dir {d}")
    return reasons


def group_of(path):
    """Which functional area a file belongs to on the FUNCTION line.

    The user's own grouping (2026-09-28): "the trip, long trip and in out
    resident, sign test to another test line". Everything else that needs the
    shipped packs is grouped with the pack loaders.
    """
    if path.endswith("urban_area_test.dart") or "urban_limit_change" in path:
        return "resident"
    if "road_signs_test.dart" in path:
        return "signs"
    if "speed_limits_test.dart" in path:
        return "limits"
    if "trip" in path or "replay" in path:
        return "trip"
    return "packs"


def main():
    if "--emit" in sys.argv:
        # <line>\t<group>\t<path> — for driving the split from the rule.
        for p in sorted(glob.glob("test/**/*_test.dart", recursive=True)):
            if classify(p):
                print(f"func\t{group_of(p)}\t{p}")
            else:
                print(f"unit\t-\t{p}")
        return

    show = "--list" in sys.argv
    files = sorted(glob.glob("test/**/*_test.dart", recursive=True))
    func, unit = [], []
    for p in files:
        reasons = classify(p)
        (func if reasons else unit).append((p, reasons))

    print(f"total: {len(files)} test files")
    print(f"  FUNCTIONAL (real data): {len(func)}")
    print(f"  UNIT (self-contained) : {len(unit)}")
    print()
    print("FUNCTIONAL:")
    for p, r in func:
        print(f"  {p}")
        if show:
            for x in sorted(set(r)):
                print(f"      - {x}")
    print()
    print("UNIT:")
    for p, _ in unit:
        print(f"  {p}")


if __name__ == "__main__":
    main()
