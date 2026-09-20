#!/usr/bin/env python3
"""Rebuild the Waze-linked NavBridge offline assets from the CORRECTED v2
point-notice DB + real WME camera (permanentHazards) data.

Fixes two bugs in the previous pipeline:
  1. The old code classified mod point-notice types 12/13 as "speed cameras"
     and injected ~4,659 bogus `source=waze` "Camera tốc độ" entries into
     vietnam_cameras.json. Cross-check proved 12/13 are SPEED LIMITS
     (posted kmh on a ~300 m segment), not cameras. They now go into
     waze_speed_limits.json (and as `speed` sign points), NOT cameras.
  2. The sign builder read the stale point_notices_all.tsv. It now reads the
     rebuilt point_notices_v2.tsv (corrected per decompiled Signs.java).

What it does:
  * SIGNS   : merge v2 sign types into vietnam_signs.json (5dp coord dedup)
  * SPEED   : merge v2 type-12/13 speed limits into waze_speed_limits.json
  * CAMERAS : DROP every previous `source=waze` camera (they were speed
              limits), then ADD real enforcement cameras from WME
              permanentHazards type 10 with subtypes (RED_LIGHT/SPEED/
              MOBILE_PHONE/SEATBELT/DISTANCE/BUS_LANE/STOP), skipping DUMMY.
"""
import json
import re
from collections import Counter

DECODE  = "/Users/tungdl/Documents/Eink/Decode_Waze"
V2      = f"{DECODE}/point_notices_v2.tsv"      # corrected signs + speed limits
HAZ     = f"{DECODE}/vn_point_notices.tsv"      # crawl: permanentHazards + segments
ASSET   = "/Users/tungdl/Documents/Eink/navbridge/assets/offline_map"
SIGN    = f"{ASSET}/vietnam_signs.json"
CAM     = f"{ASSET}/vietnam_cameras.json"
SPEED   = f"{ASSET}/waze_speed_limits.json"

# v2 type -> (VN kind key, VN label)  (from decompiled Signs.java + NGD)
TYPE_KIND = {
    2:  ("no_left_uturn",  "P.123a Cấm rẽ trái và quay đầu"),
    5:  ("no_left_uturn",  "P.123a Cấm rẽ trái và quay đầu"),
    6:  ("no_right_uturn", "P.124a Cấm rẽ phải và quay đầu"),
    7:  ("no_right_uturn", "P.124a Cấm rẽ phải và quay đầu"),
    8:  ("no_left_turn",   "P.123 Cấm rẽ trái"),
    16: ("no_left_turn",   "P.123 Cấm rẽ trái"),
    9:  ("no_right_turn",  "P.124 Cấm rẽ phải"),
    17: ("no_right_turn",  "P.124 Cấm rẽ phải"),
    11: ("no_u_turn",      "P.125 Cấm quay đầu"),
    18: ("no_u_turn",      "P.125 Cấm quay đầu"),
    14: ("no_passing",     "P.127 Cấm vượt"),
    15: ("no_passing_end", "Hết cấm vượt"),
    19: ("no_auto",        "Cấm ô tô"),
    20: ("no_moto",        "Cấm xe máy"),
    21: ("only_straight",  "R.411 Hướng phải đi thẳng"),
    22: ("only_right",     "R.412 Hướng phải rẽ phải"),
    23: ("only_left",      "R.412a Hướng phải rẽ trái"),
    26: ("populated",      "Bắt đầu khu đông dân cư"),
    27: ("populated_end",  "Hết khu đông dân cư"),
    35: ("end_prohibitions", "P.133 Hết mọi lệnh cấm"),
    32: ("one_way",        "Đường một chiều"),
    3:  ("no_straight",    "Cấm đi thẳng"),
    4:  ("no_turn_both",   "Cấm rẽ trái & phải"),
    10: ("no_straight",    "Cấm đi thẳng"),
    24: ("reserved_lane",  "Làn dành riêng"),
    25: ("no_parking",     "Cấm đỗ xe"),
    33: ("one_way",        "Đường một chiều"),
}
# speed-limit types -> SPeed value becomes a `speed` sign point (R.301).
SPEED_TYPES = {12, 13}

# camera subtype (from vn_point_notices.tsv / WME permanentHazards) -> focus/type
CAM_FOCUS = {
    "RED_LIGHT":    ("red_light",  "red_light_camera"),
    "SPEED":        ("speed",      "speed_camera"),
    "MOBILE_PHONE": ("violations", "phone_camera"),
    "SEATBELT":     ("violations", "seatbelt_camera"),
    "DISTANCE":     ("violations", "distance_camera"),
    "BUS_LANE":     ("violations", "bus_lane_camera"),
    "HOV_LANE":     ("violations", "hov_lane_camera"),
    "CARPOOL_LANE": ("violations", "carpool_lane_camera"),
    "STOP":         ("violations", "stop_camera"),
    "NOISE":        ("violations", "noise_camera"),
}
BOOTLEG = {"DUMMY"}  # fake/decoy cameras -> skip


def merge_signs():
    import json
    doc = json.load(open(SIGN))
    existing = doc.get("signs", [])
    keys = {(s["lat"], s["lng"], s.get("kind")) for s in existing}

    added = 0
    per_kind = Counter()
    rows = []
    for line in open(V2):
        p = line.rstrip("\n").split("\t")
        if len(p) < 6 or p[1] == "type":
            continue
        code = int(p[1])
        lat, lng = float(p[2]), float(p[3])
        kmh = int(p[5]) if p[5] else None
        if code in SPEED_TYPES:
            # A speed-limit sign needs a posted value to be useful — without it
            # there's no number for the icon (and it produced null-value signs).
            if not kmh:
                continue
            kind, label = "speed", f"Hạn chế tốc độ {kmh} km/h"
        else:
            pair = TYPE_KIND.get(code)
            if not pair:
                continue
            kind, label = pair
        key = (round(lat, 5), round(lng, 5), kind)
        if key in keys:
            continue
        keys.add(key)
        e = {"name": label, "lat": round(lat, 5), "lng": round(lng, 5), "kind": kind}
        if kmh:
            e["value"] = kmh
        existing.append(e)
        added += 1
        per_kind[kind] += 1

    doc["signs"] = existing
    json.dump(doc, open(SIGN, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"[SIGNS] +{added} Waze signs -> {len(existing)} total")
    print("  by kind:", dict(per_kind.most_common()))


def merge_speed():
    import json
    doc = json.load(open(SPEED))
    pts = doc.setdefault("points", [])
    keys = {(round(p["lat"], 5), round(p["lng"], 5)) for p in pts}
    added = 0
    seen = {}
    for line in open(V2):
        p = line.rstrip("\n").split("\t")
        if len(p) < 6 or p[1] not in ("12", "13"):
            continue
        try:
            lat, lng = float(p[2]), float(p[3])
            kmh = int(p[5]) if p[5] else 0
        except ValueError:
            continue
        k = (round(lat, 5), round(lng, 5))
        if kmh > seen.get(k, 0):
            seen[k] = kmh
    for k, kmh in seen.items():
        if k in keys:
            continue
        keys.add(k)
        pts.append({"lat": round(k[0], 5), "lng": round(k[1], 5), "kmh": kmh})
        added += 1
    doc["points"] = pts
    json.dump(doc, open(SPEED, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"[SPEED] +{added} Waze speed limits -> {len(pts)} total")


def fix_cameras():
    import json
    doc = json.load(open(CAM))
    cams = doc.get("cameras", [])
    # 1) drop bogus previous waze cameras (they were speed limits, not cams)
    kept = [c for c in cams if c.get("source") != "waze"]
    dropped = len(cams) - len(kept)
    keys = {(round(c["lat"], 5), round(c["lng"], 5), c.get("focus")) for c in kept}

    # 2) add real enforcement cameras from permanentHazards (type 10)
    added = 0
    per_focus = Counter()
    for line in open(HAZ):
        p = line.rstrip("\n").split("\t")
        if len(p) < 9 or p[2] != "10":
            continue
        sub = p[3]
        lat, lng = float(p[4]), float(p[5])
        subs = [s for s in sub.split(",") if s and s not in BOOTLEG]
        if not subs:
            continue
        # prefer the most specific subtype: red_light > speed > violations
        focus = "violations"
        ctype = None
        for s_pri in ("RED_LIGHT", "SPEED", "MOBILE_PHONE", "SEATBELT",
                      "DISTANCE", "BUS_LANE", "HOV_LANE", "CARPOOL_LANE",
                      "STOP", "NOISE"):
            if s_pri in subs:
                focus, ctype = CAM_FOCUS[s_pri]
                break
        key = (round(lat, 5), round(lng, 5), focus)
        if key in keys:
            continue
        keys.add(key)
        e = {"name": "Camera", "lat": round(lat, 5), "lng": round(lng, 5),
             "focus": focus, "source": "waze"}
        if ctype:
            e["type"] = ctype
        kept.append(e)
        added += 1
        per_focus[focus] += 1

    doc["cameras"] = kept
    json.dump(doc, open(CAM, "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"[CAMS] dropped {dropped} bogus waze speed-camera entries")
    print(f"[CAMS] +{added} real enforcement cameras -> {len(kept)} total")
    print("  by focus:", dict(per_focus.most_common()))


if __name__ == "__main__":
    merge_signs()
    merge_speed()
    fix_cameras()
    print("\nDone. Backup originals exist as *.bak_rich / *.bak_t9_* if you need to revert.")
