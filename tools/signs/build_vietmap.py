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
  * Direction = heading angle (0-359 deg)

Usage:
    python3 tools/signs/build_vietmap.py [edog_data.txt]
"""
import json
import os
import sys
from collections import Counter
from pathlib import Path

ASSET = Path(__file__).resolve().parent.parent.parent / "assets" / "offline_map"
CAM = ASSET / "vietnam_cameras.json"
SIGN = ASSET / "vietnam_signs.json"
SPD = ASSET / "vietmap_speed_limits.json"

# EDOG type -> camera (focus, name, type)
EDOG_CAM = {
    4: ("violations", "Camera giám sát giao thông", "traffic_camera"),
    10: ("speed", "Camera tốc độ", "speed_camera"),
}
# EDOG type -> sign kind
EDOG_SIGN = {
    1: "speed",
    2: "populated",
    3: "populated_end",
    5: "no_passing",
    6: "no_passing_end",
    7: "slow_down",
    8: "toll_booth",
    9: "tunnel",
}
SIGN_NAMES = {
    "speed": "Hạn chế tốc độ",
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
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("POINT"):
                continue
            p = line.split("\t")
            if len(p) < 4:
                continue
            try:
                lng = int(p[0]) / 1e6
                lat = int(p[1]) / 1e6
                t = int(p[2])
                spd = int(p[3])
                direction = int(p[5]) if len(p) >= 6 else 0
                rows.append((lng, lat, t, spd, direction))
            except ValueError:
                continue
    return rows


def main():
    edog = sys.argv[1] if len(sys.argv) > 1 else None
    src = find_edog(edog)
    rows = parse_edog(src)

    # Dedup by (type, lat_5dp, lng_5dp) to preserve distinct features within the same cell
    seen = {}
    for lng, lat, t, spd, direction in rows:
        k = (t, round(lat, 5), round(lng, 5))
        if k not in seen or spd > seen[k][3]:
            seen[k] = (lng, lat, t, spd, direction)

    print(f"[vietmap] edog: {src}  rows={len(rows)}  unique(type+5dp)={len(seen)}")

    # ---- 1. speed limits (type 1) -> vietmap_speed_limits.json ---------------
    spd_pts = []
    existing_spd = set()
    for lng, lat, t, spd, direction in seen.values():
        if t != 1 or spd <= 0 or spd > 200:
            continue
        k = (round(lat, 5), round(lng, 5))
        if k in existing_spd:
            continue
        existing_spd.add(k)
        pt = {"lat": round(lat, 6), "lng": round(lng, 6), "kmh": spd}
        if direction > 0:
            pt["heading"] = direction
        spd_pts.append(pt)
    spd_pts.sort(key=lambda p: (p["lat"], p["lng"]))
    spd_doc = {"version": 1, "points": spd_pts}
    json.dump(spd_doc, open(SPD, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"  speed limits: wrote {len(spd_pts)} VietMap type-1 to {SPD.name}")

    # ---- 2. cameras (types 4,10) -> vietnam_cameras.json ---------------------
    cam_doc = json.load(open(CAM, encoding="utf-8"))
    cams = [c for c in cam_doc.get("cameras", []) if c.get("source") != "vietmap"]
    cam_keys = {
        (round(c["lat"], 5), round(c["lng"], 5), c.get("focus")) for c in cams
    }
    added_cam = 0
    per_focus = Counter()
    for lng, lat, t, spd, direction in seen.values():
        if t not in EDOG_CAM:
            continue
        focus, name, rtype = EDOG_CAM[t]
        k = (round(lat, 5), round(lng, 5), focus)
        if k in cam_keys:
            continue
        cam_keys.add(k)
        e = {
            "name": name,
            "lat": round(lat, 6),
            "lng": round(lng, 6),
            "focus": focus,
            "type": rtype,
            "district": "VietMap",
            "source": "vietmap",
        }
        if spd > 0:
            e["speed_limit"] = spd
        if direction > 0:
            e["heading"] = direction
        cams.append(e)
        added_cam += 1
        per_focus[focus] += 1
    cam_doc["cameras"] = cams
    json.dump(cam_doc, open(CAM, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"  cameras: +{added_cam} VietMap cams -> {len(cams)} total")
    print("    by focus:", dict(per_focus.most_common()))

    # ---- 3. signs (types 2,3,5,6,7,8,9) -> vietnam_signs.json ----------------
    sign_doc = json.load(open(SIGN, encoding="utf-8"))
    # Keep non-vietmap signs, and keep non-EDOG VietMap signs (e.g. turn signs)
    edog_kinds = set(EDOG_SIGN.values())
    signs = [
        s for s in sign_doc.get("signs", [])
        if not (s.get("source") == "vietmap" and s.get("kind") in edog_kinds)
    ]
    sign_keys = {
        (s.get("kind"), round(s["lat"], 5), round(s["lng"], 5)) for s in signs
    }
    added_sign = 0
    per_kind = Counter()
    for lng, lat, t, spd, direction in seen.values():
        if t not in EDOG_SIGN:
            continue
        kind = EDOG_SIGN[t]
        if kind == "speed" and (spd <= 0 or spd > 200):
            continue
        k = (kind, round(lat, 5), round(lng, 5))
        if k in sign_keys:
            continue
        sign_keys.add(k)
        label = f"Hạn chế tốc độ {spd} km/h" if kind == "speed" else SIGN_NAMES.get(kind, kind)
        e = {
            "name": label,
            "lat": round(lat, 6),
            "lng": round(lng, 6),
            "kind": kind,
            "source": "vietmap",
        }
        if kind == "speed":
            e["value"] = spd
        elif kind == "populated":
            e["value"] = 40
        if direction > 0:
            e["heading"] = direction
        signs.append(e)
        added_sign += 1
        per_kind[kind] += 1
    sign_doc["signs"] = signs
    json.dump(sign_doc, open(SIGN, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"  signs: +{added_sign} VietMap signs -> {len(signs)} total")
    print("    by kind:", dict(per_kind.most_common()))


if __name__ == "__main__":
    main()

