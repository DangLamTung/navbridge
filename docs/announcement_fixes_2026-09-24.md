# Announcement fixes: the next street's speed, and one red-light warning (2026-09-24)

Two things the driver heard were wrong.

## 1. "when announcement, the next street speed is not correct, still taken from old street"

`_announce` (nav_voice.dart) builds "Đi trên Y, sau N mét, rẽ … vào X. Tốc độ tối đa
K km/h." — the sentence names the street you turn INTO, but K was
`_effectiveSpeedLimit`: the limit of the street **under the car** (Y).

Measured on the recorded drives with `tool/announce_speed_audit.py`:

| trip | quotes a street the sentence names | quotes the street under the car | falsifiable rows |
|---|---|---|---|
| 2026-09-23 17:46 (phone, before) | 16/21 (coincidence: everything is 50) | 4/21 | **0/2** |
| 2026-09-24 09:24 (replay, after) | **6/6** | **0/6** | **5/5** |

"Falsifiable" = rows where the named street's limit differs from the current
street's, so the number proves where it came from. The 6 clear pre-fix errors:

```
spoken 60 for Phan Đình Giót (really 50)  — quoted Nguyễn Văn Trỗi 60
spoken 50 for Cộng Hòa (really 60)        — quoted Hầm chui Phan Thúc Duyện 50
spoken 50 for Trường Chinh (really 60)    — quoted Ấp Bắc 50
spoken 50 for Lý Thường Kiệt (really 60)  — quoted Lạc Long Quân 50
spoken 60 for Ấp Bắc (really 50) ×2       — quoted Trần Quốc Hoàn 60 / Cộng Hòa 60
```

The fix: per maneuver, resolve the limit of the road being entered, once.

* `pointPast()` (services/offline_geo.dart) walks the ROUTE polyline to the
  maneuver and 30 m beyond it, so the sample is on the far side of the turn — a
  free-floating probe in the car's heading would land back on the old street.
  Unit tested (`test/next_street_limit_geometry_test.dart`): past the corner = new
  leg, before the corner = old leg, never a parallel street, off-route refused.
* the sample is queried with the **outgoing bearing**, which picks the right
  carriageway when a road posts a different limit per direction;
* the segment that supplied the value must be the street the engine named
  (`postedLimitMatchesName` — the same veto the chip applies), otherwise the
  sample landed on a crossing street and **nothing** is spoken;
* the value is capped for the vehicle (`effectiveLimit(..., postedSrc: srcSegment)`);
* unknown ⇒ the sentence simply has no speed in it. A wrong number is worse than
  none.

The lookup is async, so callouts are spoken from `_speakManeuver`, which awaits
`_ensureNextStreetLimit` first (the four cache fields live on the page state —
`nav_voice.dart` is an extension and cannot declare fields).

## 2. "we have đèn đỏ and đèn giao thông sắp tới which is overlap and not needed"

A junction with a traffic light (OSM `signal`, announced "Đèn giao thông sắp tới"
at ≤100 m) **and** a red-light camera in our DB (announced "Camera đèn đỏ …") gave
the driver two warnings for one hazard. The camera alert is kept — it names what
to watch for and carries a source — and the light callout is now skipped when
`_nextCamera` is a red-light camera within 150 m of the sign
(`_redLightCameraNear`, nav_signs.dart). Where there is no camera the light is
still announced: in the post-fix replay the 3 surviving light callouts sit 1,118 m,
137 m and 44 m from the nearest camera callout, whose own junction was 363 m
further on — none of them the same junction.

## Verification

* `flutter analyze` clean; `flutter test` green (geometry test added).
* Emulator, the same 3.84 km recorded drive replayed against the SIM_ROUTE build:
  `docs/trips/device/2026-09-24_092420_Chuyến_đi.json`, audited with
  `python3 tool/announce_speed_audit.py <trip>` → 6/6 and 5/5 falsifiable.
