#!/usr/bin/env python3
"""The rows the APP actually loads from `vietnam_signs.json`.

An offline audit that reads the raw file measures a database the app never uses:
`offline_road_signs.dart` drops rows before they reach the map or the voice —

  * `droppedSignKinds`      — 'populated' / 'populated_end' (the built-up boundary
                              layer, removed because its data wrote wrong limits);
  * `signCoordsAreUsable`   — fewer than `kMinSignDecimals` (4) decimals in lat or
                              lng, i.e. a coordinate snapped to a ~111 m grid, too
                              coarse to place a sign on a road;
  * `isImpossibleSpeedSign` — a speed sign whose value cannot exist.

Reading the file without those filters is what produced a "16 % of the signs are
outside Vietnam" claim that turned out to be mostly rows the app had already
thrown away. Use this module (or the same rules) for any placement/precision
audit, so the numbers describe the shipped behaviour.
"""
from __future__ import annotations

import json
from pathlib import Path

# Mirror of `droppedSignKinds` in lib/services/offline_road_signs.dart.
DROPPED_KINDS = {"populated", "populated_end"}

# Mirror of `kMinSignDecimals`.
MIN_DECIMALS = 4

# ⭐ NOT the app's rule. The Dart loader (`isImpossibleSpeedSign`) discards a speed
# value only when it is <= 0 or > kVnMaxPostedKmh (120) — 6 rows. Keeping this
# stricter allow-list here made every audit report "app loads 33,995" when the
# app loads **34,126**: 131 legal-but-unlisted values (15, 55, 65, 75 …) were
# counted as dropped. Kept for reference only; `is_impossible_speed` mirrors Dart.
PLAUSIBLE_SPEED = {20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 110, 120}

# Mirror of `kVnMaxPostedKmh` in lib/services/offline_road_signs.dart.
MAX_POSTED_KMH = 120


def _decimals(value: float) -> int:
    text = repr(float(value))
    if "e" in text or "E" in text:
        # Scientific notation: take the exponent's worth of precision.
        return max(0, -int(text.split("e-")[1])) if "e-" in text else 0
    return len(text.split(".")[1].rstrip("0")) if "." in text else 0


def coords_usable(row: dict) -> bool:
    return (
        _decimals(row["lat"]) >= MIN_DECIMALS
        and _decimals(row["lng"]) >= MIN_DECIMALS
    )


def is_impossible_speed(row: dict) -> bool:
    """Exact mirror of the Dart `isImpossibleSpeedSign` — `<= 0 or > 120`."""
    if row.get("kind") != "speed":
        return False
    v = row.get("value")
    return v is not None and (int(v) <= 0 or int(v) > MAX_POSTED_KMH)


def load_app_signs(path: str | Path) -> tuple[list[dict], dict[str, int]]:
    """Rows the app keeps, plus a count of what was dropped and why."""
    doc = json.loads(Path(path).read_text())
    rows = doc if isinstance(doc, list) else doc.get("signs", [])
    stats = {"total": len(rows), "droppedKind": 0, "coarse": 0, "impossible": 0}
    kept: list[dict] = []
    for r in rows:
        if r.get("kind") in DROPPED_KINDS:
            stats["droppedKind"] += 1
            continue
        if is_impossible_speed(r):
            stats["impossible"] += 1
            continue
        if not coords_usable(r):
            stats["coarse"] += 1
            continue
        kept.append(r)
    stats["kept"] = len(kept)
    return kept, stats
