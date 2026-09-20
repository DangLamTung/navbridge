#!/usr/bin/env python3
"""Drop Waze speed-LIMIT point-notices from vietnam_cameras.json — but keep
real Waze enforcement cameras.

Distinction (verified 2026-09-08):
  * bogus  : source=='waze' AND focus=='speed' AND no real camera `type`.
    These are the Waze speed-limit point-notices (road segments / intersections,
    e.g. "Quốc lộ 1A đoạn từ Km 2232 đến Km 2240", "Ngã tư giao nhau ...") that
    are NOT enforcement cameras. The app was announcing "Camera tốc độ" for
    what is really speed-limit data (user: "the waze announcement still speed
    camera"). They carry no posted limit (speed_limit == 0) and no camera
    subtype, so we cannot name a camera from them.
  * real   : source=='waze' AND type in {speed_camera, red_light_camera,
    phone_camera, seatbelt_camera, distance_camera, bus_lane_camera,
    hov_lane_camera, carpool_lane_camera, stop_camera, noise_camera}.
    These are genuine WME permanentHazards type-10 enforcement cameras and
    should stay (we only drop the speed-limit sign data).

The earlier `tool/clean_cameras_drop_waze.py` dropped ALL source=='waze'
entries — too broad, it removed real enforcement cameras too.

Usage (from repo root):
  python3 tools/signs/clean_waze_speed_limits.py            # dry-run
  python3 tools/signs/clean_waze_speed_limits.py --write     # backup + rewrite
"""
import json
import os
import sys
import collections

ASSET = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "assets", "offline_map",
    "vietnam_cameras.json",
))

# Real WME enforcement-camera subtypes we KEEP.
REAL_CAMERA_TYPES = {
    "speed_camera", "red_light_camera", "phone_camera", "seatbelt_camera",
    "distance_camera", "bus_lane_camera", "hov_lane_camera",
    "carpool_lane_camera", "stop_camera", "noise_camera",
}


def is_bogus(c):
    return (c.get("source") == "waze"
            and c.get("focus") == "speed"
            and c.get("type") not in REAL_CAMERA_TYPES)


def main():
    write = "--write" in sys.argv
    doc = json.load(open(ASSET))
    cams = doc.get("cameras", [])

    bogus = [c for c in cams if is_bogus(c)]
    keep = [c for c in cams if not is_bogus(c)]

    print(f"total before: {len(cams)}")
    print(f"bogus Waze speed-limit point-notices dropped: {len(bogus)}")
    print(f"kept: {len(keep)}")
    print(f"kept focus: {dict(collections.Counter(c['focus'] for c in keep))}")
    print(f"kept source: {dict(collections.Counter(c.get('source', '?') for c in keep))}")

    tagged = [c for c in keep if (c.get("district") or "").strip()]
    provinces = {c["district"] for c in tagged}
    print(f"tagged: {len(tagged)}/{len(keep)} = {len(tagged) / max(len(keep), 1):.2%}"
          f" (test needs >60%)  provinces: {len(provinces)} (test needs >=55)")

    if not write:
        print("dry-run: no files changed (pass --write to apply)")
        return 0

    bak = ASSET + ".bak_pre_waze_limit_clean"
    if not os.path.exists(bak):
        import shutil
        shutil.copy2(ASSET, bak)
        print("backup:", os.path.basename(bak))

    doc["version"] = (doc.get("version") or 1) + 1
    doc["cameras"] = keep
    json.dump(doc, open(ASSET, "w"), ensure_ascii=False, separators=(",", ":"))
    print("wrote", ASSET, "version", doc["version"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
