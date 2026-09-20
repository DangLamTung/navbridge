#!/usr/bin/env python3
"""Merge VietMap KC01 EDOG traffic-warning data into the NavBridge offline
assets (cameras / speed-limits / signs).

The VietMap KC01 device publishes an `edog_data.txt` each month (the product
update page: https://vietmap.vn/cap-nhat-ban-do-vietmap-kc01). It carries the
official VietMap crash-warning layer:

    POINT_X  POINT_Y  TYPE  Speed  DirType  Direction
    102449210 22200879  3      0      1       314

  * POINT_X / POINT_Y = longitude / latitude * 1e6
  * TYPE 1 = speed limit, 2 = residential start, 3 = residential end,
           4 = traffic camera, 5 = no-passing, 6 = end no-passing,
           7 = slow-down, 8 = toll booth, 9 = tunnel, 10 = speed camera
  * Speed = posted km/h (0 when n/a)

This MERGES into the existing assets (it does NOT rebuild from scratch), so the
Waze-crawled data that rebuild_waze_assets.py adds is preserved. Run it AFTER
rebuild_waze_assets.py in the monthly flow.

Usage:
    python3 tools/signs/build_vietmap.py [edog_data.txt]
    # default: newest local edog_data.txt under Decode_Waze
"""
import json
import os
import sys
from collections import Counter
from pathlib import Path

ASSET = Path(__file__).resolve().parent.parent.parent / "assets" / "offline_map"
CAM = ASSET / "vietnam_cameras.json"
SIGN = ASSET / "vietnam_signs.json"
SPD = ASSET / "waze_speed_limits.json"

# EDOG type -> camera (focus, name, type)
EDOG_CAM = {
    4: ("violations", "Camera giám sát giao thông", "traffic_camera"),
    10: ("speed", "Camera tốc độ", "speed_camera"),
}
# EDOG type -> sign kind
EDOG_SIGN = {
    2: "populated",
    3: "populated_end",
    5: "no_passing",
    6: "no_passing_end",
    7: "slow_down",
    8: "toll_booth",
    9: "tunnel",
}
SIGN_NAMES = {
    "populated": "Khu đông dân cư",
    "populated_end": "Hết khu đông dân cư",
    "no_passing": "Cấm vượt",
    "no_passing_end": "Hết cấm vượt",
    "slow_down": "Giảm tốc độ",
    "toll_booth": "Trạm thu phí",
    "tunnel": "Hầm đường bộ",
}


def find_edog(path: str) -> Path:
    if path:
        p = Path(path)
        if p.exists():
            return p
        sys.exit(f"edog_data.txt not found: {path}")
    roots = [
        Path(__file__).resolve().parent.parent / "data" / "vietmap_kc01",
        Path(os.environ.get("DECODE_WAZE_DIR", "/Users/tungdl/Documents/Eink/Decode_Waze")),
    ]
    best = None
    for root in roots:
        if not root.exists():
            continue
        for p in root.rglob("edog_data.txt"):
            if best is None or p.stat().st_mtime > best.stat().st_mtime:
                best = p
    if best is None:
        sys.exit("No edog_data.txt found in search roots")
    return best


def parse_edog(path: Path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("POINT"):
                continue
            p = line.split("\t")
            if len(p) < 4:
                continue
            try:
                rows.append((int(p[0]) / 1e6, int(p[1]) / 1e6, int(p[2]), int(p[3])))
            except ValueError:
                continue
    return rows


def main():
    edog = sys.argv[1] if len(sys.argv) > 1 else None
    src = find_edog(edog)
    rows = parse_edog(src)
    # self-dedup by ~100 m (3dp), keep highest speed per cell
    seen = {}
    for lng, lat, t, spd in rows:
        k = (round(lat, 3), round(lng, 3))
        if k not in seen or spd > seen[k][3]:
            seen[k] = (lng, lat, t, spd)

    print(f"[vietmap] edog: {src}  rows={len(rows)}  unique(~100m)={len(seen)}")

    # ---- 1. speed limits (type 1) -> waze_speed_limits.json ------------------
    spd_doc = json.load(open(SPD))
    spd_pts = spd_doc.setdefault("points", [])
    existing = {(round(i["lat"], 5), round(i["lng"], 5)) for i in spd_pts}
    added_speed = 0
    # NOTE: iterate the VALUES — `seen` is keyed by a 0.001° cell (~100 m) and
    # the value carries the REAL coordinates. Writing the key instead snapped
    # every VietMap point onto a ~111 m grid (up to ~78 m off the road), which
    # is exactly why the VietMap traffic cameras did not line up with the road.
    for lng, lat, t, spd in seen.values():
        if t != 1 or spd <= 0:
            continue
        k = (round(lat, 5), round(lng, 5))
        if k in existing:
            continue
        existing.add(k)
        spd_pts.append({"lat": round(lat, 6), "lng": round(lng, 6), "kmh": spd})
        added_speed += 1
    json.dump(spd_doc, open(SPD, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"  speed limits: +{added_speed} VietMap type-1 -> {len(spd_pts)} total")

    # ---- 2. cameras (types 4,10) -> vietnam_cameras.json ----------------------
    cam_doc = json.load(open(CAM))
    cams = cam_doc.setdefault("cameras", [])
    cam_keys = {
        (round(c["lat"], 5), round(c["lng"], 5), c.get("focus")) for c in cams
    }
    added_cam = 0
    per_focus = Counter()
    for lng, lat, t, spd in seen.values():
        if t not in EDOG_CAM:
            continue
        focus, name, rtype = EDOG_CAM[t]
        k = (round(lat, 5), round(lng, 5), focus)
        if k in cam_keys:
            continue
        cam_keys.add(k)
        e = {
            "name": name, "lat": round(lat, 6), "lng": round(lng, 6),
            "focus": focus, "type": rtype, "district": "VietMap",
            "source": "vietmap",
        }
        if spd > 0:
            e["speed_limit"] = spd
        cams.append(e)
        added_cam += 1
        per_focus[focus] += 1
    json.dump(cam_doc, open(CAM, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"  cameras: +{added_cam} VietMap cams -> {len(cams)} total")
    print("    by focus:", dict(per_focus.most_common()))

    # ---- 3. signs (types 2,3,5,6,7,8,9) -> vietnam_signs.json -----------------
    sign_doc = json.load(open(SIGN))
    signs = sign_doc.setdefault("signs", [])
    sign_keys = {
        (s.get("kind"), round(s["lat"], 5), round(s["lng"], 5)) for s in signs
    }
    added_sign = 0
    per_kind = Counter()
    for lng, lat, t, spd in seen.values():
        if t not in EDOG_SIGN:
            continue
        kind = EDOG_SIGN[t]
        k = (kind, round(lat, 5), round(lng, 5))
        if k in sign_keys:
            continue
        sign_keys.add(k)
        e = {
            "name": SIGN_NAMES.get(kind, kind),
            "lat": round(lat, 6), "lng": round(lng, 6), "kind": kind,
            "source": "vietmap",
        }
        if kind == "populated":
            e["value"] = 40
        signs.append(e)
        added_sign += 1
        per_kind[kind] += 1
    json.dump(sign_doc, open(SIGN, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"  signs: +{added_sign} VietMap signs -> {len(signs)} total")
    print("    by kind:", dict(per_kind.most_common()))


if __name__ == "__main__":
    main()
