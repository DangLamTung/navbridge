#!/usr/bin/env python3
"""Merge the VietMap E-DOG warning-point dataset into the NavBridge offline DB.

edog (VietMap KC01 E-DOG) is a nation-wide set of real posted speed limits,
enforcement cameras and traffic signs. It must NOT be dumped wholesale into the
camera DB (the old vietmap_edog_to_navbridge.py did that and would re-introduce
"announce speed camera for a sign"). Instead split it by the correct layer:

  TYPE 1 SpeedLimit   -> assets/offline_map/vietmap_speed_limits.json (point layer,
                         read by offline_speed_limits.dart speedLimitAt)
  TYPE 2 SpeedCamera  -> vietnam_cameras.json  focus=speed  type=speed_camera
  TYPE 3 TrafficCamera-> vietnam_cameras.json  focus=violations type=traffic_camera
  TYPE 4 PenaltyCamera-> vietnam_cameras.json  focus=violations type=penalty_camera
  TYPE 5 SlowDown     -> vietnam_signs.json   kind=slow_down
  TYPE 6 TollBooth    -> vietnam_signs.json   kind=toll_booth
  TYPE 7 Tunnel       -> vietnam_signs.json   kind=tunnel
  TYPE 8 RailWay      -> vietnam_signs.json   kind=railway_crossing
  TYPE 9 Residental   -> vietnam_signs.json   kind=populated
  TYPE 10 OutResidental-> vietnam_signs.json  kind=populated_end

Dedup: 5dp coordinate dedup within the source + against the existing DB.
Originals are backed up to .bak before writing. Add the new speed-limit asset
to pubspec.yaml (offline_map assets are listed individually).
"""

import datetime
import json
import shutil
import sys
import collections
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDOG = (
    Path("/Users/tungdl/Documents/Eink/Decode_Waze/vietmap_kc01")
    / "edog_points_labeled.geojson"
)
SL_OUT = ROOT / "assets/offline_map/vietmap_speed_limits.json"
CAM = ROOT / "assets/offline_map/vietnam_cameras.json"
SIGN = ROOT / "assets/offline_map/vietnam_signs.json"

CAM_MAP = {
    2: ("speed", "speed_camera", "Vietmap Camera tốc độ"),
    3: ("violations", "traffic_camera", "Vietmap Camera giám sát giao thông"),
    4: ("violations", "penalty_camera", "Vietmap Camera phạt nguội"),
}
SIGN_MAP = {
    5: ("slow_down", "Giảm tốc độ"),
    6: ("toll_booth", "Trạm thu phí"),
    7: ("tunnel", "Hầm đường bộ"),
    8: ("railway_crossing", "Đường ngang giao với đường sắt"),
    9: ("populated", "Bắt đầu khu đông dân cư"),
    10: ("populated_end", "Hết khu đông dân cư"),
}


def r5(v):
    return round(v, 5)


def bump_version(doc, default=1):
    """Increment a JSON 'version' that may be int or a numeric string."""
    v = doc.get("version", default)
    if isinstance(v, str):
        try:
            v = float(v)
        except ValueError:
            v = default
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        v = default
    return round(v + 1, 2)


def main() -> int:
    write = "--write" in sys.argv
    edog = json.load(open(EDOG, "r", encoding="utf-8"))
    feats = edog.get("features", [])

    # --- TYPE 1: speed limits ---
    sl_seen = {}
    for f in feats:
        p = f.get("properties", {})
        if p.get("type") != 1:
            continue
        spd = p.get("speed") or 0
        if spd < 5 or spd > 200:
            continue
        lon, lat = f["geometry"]["coordinates"]
        k = (r5(lat), r5(lon))
        # keep the highest speed for a single cell (some points carry one value)
        if k not in sl_seen or spd > sl_seen[k][2]:
            sl_seen[k] = (lat, lon, spd)
    sl_points = [{"lat": c[0], "lng": c[1], "kmh": c[2]} for c in sl_seen.values()]
    sl_points.sort(key=lambda p: (p["lat"], p["lng"]))
    print(f"speed-limit points (type 1, deduped): {len(sl_points)}")

    # --- TYPE 2/3/4: cameras ---
    cam_seen = {}
    for f in feats:
        p = f.get("properties", {})
        t = p.get("type")
        if t not in CAM_MAP:
            continue
        lon, lat = f["geometry"]["coordinates"]
        k = (r5(lat), r5(lon))
        if k not in cam_seen:
            cam_seen[k] = (lat, lon, t)
    print(f"edog camera points (types 2/3/4, deduped): {len(cam_seen)}")

    # --- TYPE 5-10: signs ---
    sign_seen = {}
    for f in feats:
        p = f.get("properties", {})
        t = p.get("type")
        if t not in SIGN_MAP:
            continue
        lon, lat = f["geometry"]["coordinates"]
        k = (r5(lat), r5(lon))
        if k not in sign_seen:
            sign_seen[k] = (lat, lon, t)
    print(f"edog sign points (types 5-10, deduped): {len(sign_seen)}")

    # --- speed limit asset ---
    sl_doc = {"version": 1, "points": sl_points}
    if write:
        SL_OUT.parent.mkdir(parents=True, exist_ok=True)
        if SL_OUT.exists():
            shutil.copy2(SL_OUT, SL_OUT.with_suffix(".json.bak"))
        json.dump(sl_doc, open(SL_OUT, "w", encoding="utf-8"), ensure_ascii=False)
        print(f"wrote {SL_OUT} ({len(sl_points)} pts)")

    # --- cameras merge ---
    cam_doc = json.load(open(CAM, "r", encoding="utf-8"))
    existing = cam_doc.get("cameras", [])
    keys = {(r5(c["lat"]), r5(c["lng"])) for c in existing}
    added_cam = 0
    for (lat, lon, t) in cam_seen.values():
        k = (r5(lat), r5(lon))
        if k in keys:
            continue
        focus, ctype, name = CAM_MAP[t]
        existing.append(
            {
                "name": name,
                "lat": round(lat, 6),
                "lng": round(lon, 6),
                "focus": focus,
                "type": ctype,
                "district": "VietMap",
                "source": "vietmap",
            }
        )
        keys.add(k)
        added_cam += 1
    print(f"cameras added: +{added_cam} -> total {len(existing)}")

    # --- signs merge ---
    sign_doc = json.load(open(SIGN, "r", encoding="utf-8"))
    existing_s = sign_doc.get("signs", [])
    skeys = {(r5(c["lat"]), r5(c["lng"])) for c in existing_s}
    added_sign = 0
    for (lat, lon, t) in sign_seen.values():
        if (r5(lat), r5(lon)) in skeys:
            continue
        kind, name = SIGN_MAP[t]
        existing_s.append(
            {
                "name": name,
                "lat": round(lat, 6),
                "lng": round(lon, 6),
                "kind": kind,
            }
        )
        skeys.add((r5(lat), r5(lon)))
        added_sign += 1
    print(f"signs added: +{added_sign} -> total {len(existing_s)}")

    if not write:
        print("dry-run: no files changed (pass --write to apply)")
        return 0

    now = datetime.date.today().isoformat()
    if added_cam:
        shutil.copy2(CAM, CAM.with_suffix(".json.bak"))
        cam_doc["version"] = bump_version(cam_doc)
        cam_doc["generated"] = now
        cam_doc["cameras"] = existing
        json.dump(
            cam_doc, open(CAM, "w", encoding="utf-8"), ensure_ascii=False
        )
    if added_sign:
        shutil.copy2(SIGN, SIGN.with_suffix(".json.bak"))
        sign_doc["version"] = bump_version(sign_doc, default=1.0)
        sign_doc["generated"] = now
        sign_doc["signs"] = existing_s
        json.dump(
            sign_doc, open(SIGN, "w", encoding="utf-8"), ensure_ascii=False
        )
    print("done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
