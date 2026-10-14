#!/usr/bin/env python3
"""Remove the 2026-10-11 generated one-way signs from the shipped pack.

Why (2026-10-11): the generator trusted the per-SEGMENT one-way flag in the WME
crawl, but WME stores a DIVIDED road as two one-way carriageways - so it put
"đường một chiều" on plainly two-way divided arterials (reported: Cộng Hòa /
Trường Chinh). Measured with tool/oneway_street_audit.py: ~1,914 street names
look one-way in part while carrying both directions somewhere.

The rows are identifiable by `source == "waze-segment"` (the marker the builder
writes), so this drops exactly them and leaves every other source untouched -
including the 10 pre-existing one_way rows from the Waze map comments.

Regenerating is a deliberate step (`tools/signs/build_oneway_signs.py --write`)
once the predicate is right; this makes the pack clean FIRST.

Run: python3 tool/drop_oneway_signs.py [--write]
"""

from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SIGNS = REPO / "assets" / "offline_map" / "vietnam_signs.json"
SOURCE = "waze-segment"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    doc = json.loads(SIGNS.read_text(encoding="utf-8"))
    rows = doc.get("signs", [])
    before = len(rows)

    keep = [x for x in rows
            if not (x.get("kind") == "one_way" and x.get("source") == SOURCE)]
    dropped = before - len(keep)

    still_oneway = [x for x in keep if x.get("kind") == "one_way"]
    print(f"signs before      : {before:,}")
    print(f"dropped (generated): {dropped:,}")
    print(f"signs after       : {len(keep):,}")
    print(f"one_way kept      : {len(still_oneway):,} "
          f"(sources: {sorted({x.get('source') for x in still_oneway})})")

    if not args.write:
        print("\n(dry run - pass --write)")
        return 0

    backup = SIGNS.with_suffix(f".json.bak-droponeway-{int(time.time())}")
    shutil.copy2(SIGNS, backup)
    print(f"backup: {backup.name}")

    doc["signs"] = keep
    doc["generated"] = (f"{time.strftime('%Y-%m-%d')} "
                        f"(-{dropped:,} one_way signs removed: the generated "
                        f"ones were on two-way divided roads)")
    SIGNS.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {SIGNS.relative_to(REPO)} "
          f"({SIGNS.stat().st_size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
