#!/usr/bin/env python3
"""Re-derive every E-DOG sign row from the source with the CORRECT type table.

Problem: `tool/merge_edog_vietmap.py` used a different EDOG type table than
`tools/signs/build_vietmap.py` (e.g. it called type 10 "out of residential zone"
when type 10 is a SPEED CAMERA, and type 5 "slow down" when it is CẤM VƯỢT).
Both scripts wrote into the same `vietnam_signs.json`, so thousands of rows carry
the wrong kind — including mid-city "kết thúc khu đông dân cư" markers standing
on speed-camera points (the user spotted one 1.2 km from Bến Thành).

What it does: drops the EDOG-owned sign kinds (source == "vietmap") and then
re-adds them from the source using the documented table via
`tools/signs/build_vietmap.py` (which is precision-correct).

Usage:
    python3 tools/signs/rebuild_edog_signs.py            # dry run
    python3 tools/signs/rebuild_edog_signs.py --write     # backup + strip, then re-add
"""

from __future__ import annotations

import argparse
import collections
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SIGN = REPO / "assets/offline_map/vietnam_signs.json"

# Kinds the E-DOG is the owner of (see build_vietmap.py EDOG_SIGN + railway from
# the old, wrong table). "speed" is NOT here: those come from the point layers
# via tools/signs/build_signs.py, not from EDOG sign types.
EDOG_KINDS = {
    "populated",
    "populated_end",
    "no_passing",
    "no_passing_end",
    "slow_down",
    "toll_booth",
    "tunnel",
    "railway_crossing",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--edog", help="edog_data.txt to re-add from")
    args = ap.parse_args()

    doc = json.load(open(SIGN, encoding="utf-8"))
    signs = doc["signs"]
    before = len(signs)

    drop = [s for s in signs if s.get("source") == "vietmap" and s.get("kind") in EDOG_KINDS]
    keep = [s for s in signs if not (s.get("source") == "vietmap" and s.get("kind") in EDOG_KINDS)]
    print(f"signs: {before} → drop {len(drop)} EDOG-source rows, keep {len(keep)}")
    per_kind = collections.Counter(s["kind"] for s in drop)
    print("  dropped by kind:", dict(per_kind.most_common()))
    src = collections.Counter(s.get("source") for s in keep)
    print("  remaining by source:", dict(src.most_common()))

    if not args.write:
        print("\nDRY RUN — nothing written. Re-run with --write.")
        return 0

    stamp = time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(SIGN, f"{SIGN}.{stamp}.bak")
    doc["signs"] = keep
    with open(SIGN, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {SIGN} (backup .{stamp}.bak)")

    cmd = [sys.executable, str(REPO / "tools/signs/build_vietmap.py")]
    if args.edog:
        cmd.append(args.edog)
    print(f"\nre-adding from the source: {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=REPO)
    if r.returncode != 0:
        print("build_vietmap.py FAILED — asset is stripped; restore the .bak",
              file=sys.stderr)
        return r.returncode

    after = len(json.load(open(SIGN, encoding="utf-8"))["signs"])
    print(f"\nsigns now: {after} (was {before})")
    print("next: python3 tools/signs/check_edog_kind_mapping.py  (expect ~0 WRONG)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
