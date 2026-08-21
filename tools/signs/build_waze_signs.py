#!/usr/bin/env python3
"""Merge Waze Mod decoded ROAD SIGNS into vietnam_signs.json using VIETNAM
STANDARD sign codes (QCVN 41:2019/BGTVT), not Waze's internal type names.

Waze point-notice type -> VN standard kind key + label:
  Waze type  | VN kind           | VN standard sign
  26         | populated         | Bắt đầu khu đông dân cư
  27         | populated_end     | Hết khu đông dân cư
  14         | no_passing        | P.127 Cấm vượt
  15         | no_passing_end    | Hết cấm vượt
  8,16       | no_left_turn      | P.123 Cấm rẽ trái
  9,17       | no_right_turn     | P.124 Cấm rẽ phải
  11,18      | no_u_turn         | P.125 Cấm quay đầu
  2,5        | no_left_uturn     | P.123a Cấm rẽ trái và quay đầu
  6,7        | no_right_uturn    | P.124a Cấm rẽ phải và quay đầu
  21         | only_straight     | R.411 Hướng phải đi thẳng
  22         | only_right        | R.412 Hướng phải rẽ phải
  23         | only_left         | R.412a Hướng phải rẽ trái
  35         | end_prohibitions  | P.133 Hết mọi lệnh cấm
  (speed cams 12/13 become 'speed' limit signs with value=kmh)

Reads Decode_Waze/point_notices_all.tsv, dedups ~100 m, and merges into
assets/offline_map/vietnam_signs.json with 5dp coord dedup.
"""
import json
import os
import sys

sys.path.insert(0, "/Users/tungdl/Documents/Eink/navbridge/tool")

SRC = "/Users/tungdl/Documents/Eink/Decode_Waze/point_notices_all.tsv"
ASSET = "/Users/tungdl/Documents/Eink/navbridge/assets/offline_map/vietnam_signs.json"

# Waze type -> (vn kind key, vn label)
TYPE_KIND = {
    26: ("populated", "Bắt đầu khu đông dân cư"),
    27: ("populated_end", "Hết khu đông dân cư"),
    14: ("no_passing", "P.127 Cấm vượt"),
    15: ("no_passing_end", "Hết cấm vượt"),
    8: ("no_left_turn", "P.123 Cấm rẽ trái"),
    16: ("no_left_turn", "P.123 Cấm rẽ trái"),
    9: ("no_right_turn", "P.124 Cấm rẽ phải"),
    17: ("no_right_turn", "P.124 Cấm rẽ phải"),
    11: ("no_u_turn", "P.125 Cấm quay đầu"),
    18: ("no_u_turn", "P.125 Cấm quay đầu"),
    2: ("no_left_uturn", "P.123a Cấm rẽ trái và quay đầu"),
    5: ("no_left_uturn", "P.123a Cấm rẽ trái và quay đầu"),
    6: ("no_right_uturn", "P.124a Cấm rẽ phải và quay đầu"),
    7: ("no_right_uturn", "P.124a Cấm rẽ phải và quay đầu"),
    21: ("only_straight", "R.411 Hướng phải đi thẳng"),
    22: ("only_right", "R.412 Hướng phải rẽ phải"),
    23: ("only_left", "R.412a Hướng phải rẽ trái"),
    35: ("end_prohibitions", "P.133 Hết mọi lệnh cấm"),
    # speed cameras -> 'speed' limit signs (the posted limit at each camera)
    12: ("speed", None),
    13: ("speed", None),
}

rows = []
with open(SRC) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        p = line.split("\t")
        if len(p) >= 6 and int(p[1]) in TYPE_KIND:
            rows.append(p)

seen = {}
for p in rows:
    t = int(p[1])
    lat, lng = float(p[2]), float(p[3])
    k = (round(lat, 3), round(lng, 3))
    kmh = int(p[5]) if p[5] else None
    # for collisions prefer non-speed (specific sign) then higher kmh
    cur = seen.get(k)
    if cur is None or (t not in (12, 13) and cur[1] in (12, 13)):
        seen[k] = (p, t, kmh)
    elif t in (12, 13) and cur[1] in (12, 13) and (kmh or 0) > (cur[2] or 0):
        seen[k] = (p, t, kmh)

signs = []
for k, (p, t, kmh) in seen.items():
    kind, label = TYPE_KIND[t]
    name = label if label else (f"Hạn chế tốc độ {kmh} km/h" if kmh else "Hạn chế tốc độ")
    signs.append({
        "name": name,
        "lat": round(k[0], 6),
        "lng": round(k[1], 6),
        "kind": kind,
        "value": kmh,
    })

from collections import Counter
print("Waze VN-standard signs (deduped):", len(signs))
print("by kind:", dict(Counter(s["kind"] for s in signs)))

# merge into existing asset (OSM) with 5dp coord dedup
doc = json.load(open(ASSET))
existing = doc.get("signs", [])
keys = {(round(s["lat"], 5), round(s["lng"], 5)) for s in existing}
added = 0
for s in signs:
    k = (s["lat"], s["lng"])
    if k not in keys:
        existing.append(s)
        keys.add(k)
        added += 1
doc["signs"] = existing
doc["generated"] = "2026-08-21 (OSM + Waze VN-standard)"
json.dump(doc, open(ASSET, "w"), ensure_ascii=False, indent=1)
print(f"merged: +{added} waze signs -> total {len(existing)} in vietnam_signs.json")
