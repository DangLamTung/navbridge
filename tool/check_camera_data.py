#!/usr/bin/env python3
"""Sanity-check the bundled camera/sign assets after a data rebuild.

Verifies:
  * coordinates are inside Vietnam's bbox
  * the share of points still snapped to the coarse 0.001° grid
    (`build_vietmap.py` used to write the dedup-cell coordinate → ~111 m error)
  * no duplicate (lat,lng,focus) / (kind,lat,lng) rows were introduced
  * how many speed cameras finally carry a posted `speed_limit`

Usage: python3 tool/check_camera_data.py
"""

from __future__ import annotations

import collections
import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(REPO, "assets/offline_map")


def on_grid(lat, lng) -> bool:
    return abs(round(lat, 6) * 1e6) % 1000 < 0.5 and abs(round(lng, 6) * 1e6) % 1000 < 0.5


def share_on_grid(rows) -> str:
    if not rows:
        return "0/0"
    k = sum(1 for r in rows if on_grid(r["lat"], r["lng"]))
    return f"{k}/{len(rows)} ({k / len(rows) * 100:.0f}%)"


def in_vn(r) -> bool:
    return 8.0 <= r["lat"] <= 23.6 and 102.0 <= r["lng"] <= 110.0


def main() -> int:
    cams = json.load(open(os.path.join(MAP, "vietnam_cameras.json")))["cameras"]
    signs = json.load(open(os.path.join(MAP, "vietnam_signs.json")))["signs"]

    print(f"cameras: {len(cams)}  | signs: {len(signs)}")
    for label, rows in (("cameras", cams), ("signs", signs)):
        print(f"  {label} outside Vietnam bbox: {sum(1 for r in rows if not in_vn(r))}")
    print()
    print("share still on the coarse 0.001° grid (should be ~0 for vietmap):")
    print(f"  all cameras            {share_on_grid(cams)}")
    print(f"  vietmap cameras        {share_on_grid([c for c in cams if c.get('source') == 'vietmap'])}")
    print(f"  waze cameras           {share_on_grid([c for c in cams if c.get('source') == 'waze'])}")
    print(f"  all signs              {share_on_grid(signs)}")
    print(f"  vietmap signs          {share_on_grid([s for s in signs if s.get('source') == 'vietmap'])}")
    print()

    dup_cam = len(cams) - len(
        {(round(c["lat"], 5), round(c["lng"], 5), c.get("focus")) for c in cams}
    )
    dup_sign = len(signs) - len(
        {(s.get("kind"), round(s["lat"], 5), round(s["lng"], 5)) for s in signs}
    )
    print(f"duplicate camera keys: {dup_cam}  | duplicate sign keys: {dup_sign}")

    by_type = collections.Counter(c.get("type") or "-" for c in cams)
    print("\ncameras by type:", dict(by_type.most_common()))
    speed = [c for c in cams if c.get("type") == "speed_camera"]
    have = [c for c in speed if (c.get("speed_limit") or 0) > 0]
    print(f"speed cameras with a posted limit: {len(have)}/{len(speed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
