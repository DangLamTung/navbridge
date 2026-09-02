#!/usr/bin/env python3
"""Drop Waze speed-limit point-notices from vietnam_cameras.json.

These entries (source=='waze', focus=='speed') are the SAME points already
served by `assets/offline_map/waze_speed_limits.json` (the per-point posted
limit layer). They are NOT enforcement cameras — they are the Waze speed-limit
point data. Leaving them in the camera DB made the app announce "Camera tốc độ"
for what is really just a speed-limit data point (the driver complained:
"announcement still say speed camera for signs").

The app already uses waze_speed_limits.json for the posted limit, so this file
keeps those points available for speed limits while removing the bogus camera
alerts.

Usage:
  python3 tool/clean_cameras_drop_waze.py            # dry-run (prints counts)
  python3 tool/clean_cameras_drop_waze.py --write     # backup + rewrite asset
"""

import json
import shutil
import sys
import collections
from pathlib import Path

ASSET = Path(__file__).resolve().parent.parent / "assets/offline_map/vietnam_cameras.json"


def main() -> int:
    write = "--write" in sys.argv
    with open(ASSET, "r", encoding="utf-8") as f:
        data = json.load(f)

    cams = data.get("cameras", [])
    waze = [c for c in cams if c.get("source") == "waze"]
    keep = [c for c in cams if c.get("source") != "waze"]

    old_ver = data.get("version")
    print(f"total before: {len(cams)}   waze dropped: {len(waze)}   keep: {len(keep)}")
    print(f"kept focus: {dict(collections.Counter(c['focus'] for c in keep))}")
    print(f"kept source: {dict(collections.Counter(c.get('source', '?') for c in keep))}")

    # Mirror the offline_camera_test.dart coverage thresholds so we can confirm
    # the cleaned DB still passes.
    tagged = [c for c in keep if (c.get("district") or "").strip()]
    provinces = {c["district"] for c in tagged}
    print(f"tagged: {len(tagged)}/{len(keep)} = {len(tagged) / max(len(keep), 1):.2%} "
          f"(test needs >60%)  provinces: {len(provinces)} (test needs >=55)")

    if not write:
        print("dry-run: no files changed (pass --write to apply)")
        return 0

    bak = ASSET.with_suffix(".json.bak")
    shutil.copy2(ASSET, bak)
    print(f"backup: {bak}")

    data["version"] = (old_ver or 1) + 1
    data["cameras"] = keep
    with open(ASSET, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {ASSET}  version {(old_ver or 1)} -> {data['version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
