# Sign artwork aligned to the Vietnamese signs, one camera icon (2026-09-23)

## The complaint
"waze sign and vietmap sign must aligned to the vietnamese sign data png, also for
the camera in start screen they must be same png camera as the navigation (taken
from waze)".

Two separate defects, both about a picture not matching its data:

1. Kinds that the **Waze decode** and the **VietMap/DATMAP dumps** emit were still
   drawn by our own painters (`_CommandPainter`, `_ProhibitionPainter`,
   `_RailwayPainter`, `_InfoPainter`) instead of the official QCVN sign.
2. The **browse (start) map** drew cameras as a Material CCTV glyph inside a
   focus-coloured circle, while the **navigation map** has always drawn the Waze
   alerter PNG (`assets/waze/icon_alerter_cam_speed.png`).

## 1. Every kind the data can emit now has real QCVN artwork

The kinds that reach the index, by generator:

| source | generator | kinds |
|---|---|---|
| Waze decode | `tools/signs/build_waze_signs.py` | speed, no_passing, no_passing_end, no_left_turn, no_right_turn, no_u_turn, no_left_uturn, no_right_uturn, only_straight, only_left, only_right, end_prohibitions, populated, populated_end |
| VietMap E-DOG | `tools/signs/build_vietmap.py` | populated, populated_end, no_passing, no_passing_end, slow_down, toll_booth, tunnel |
| DATMAP / cameras | `datmap/export_navbridge_signs.py` | populated, populated_end, no_passing, no_passing_end, no_left_turn, no_right_turn, no_left_uturn, no_right_uturn, no_u_turn |

Eleven new PNGs were fetched from Wikimedia Commons (public domain, QCVN 41
artwork), after reading each file's `ImageDescription` **and** looking at the
picture in a labelled sheet (`tools/signs/sign_contact_sheet.py` verifies the
kind ↔ file mapping afterwards):

| bundled file | Commons source | description as read |
|---|---|---|
| `no_passing.png` | `P.125 (QCVN 41-2019-BGTVT)` | No overtaking — the UNIVERSAL sign (the old bundled file was the xe-tải variant) |
| `no_auto.png` | `P103a` | No motor vehicles (car pictogram) |
| `only_straight.png` | `R301a` | Proceed straight ahead only |
| `only_left.png` | `R301e` | Các xe chỉ được rẽ trái (turning arrow) |
| `only_right.png` | `R301d` | Các xe chỉ được rẽ phải (turning arrow) |
| `one_way.png` | `I.407a (QCVN 41-2019-BGTVT)` | One way street |
| `railway_crossing.png` | `W242a` | Railway level crossing (chỗ đường sắt cắt đường bộ) |
| `tunnel.png` | `W240` | Tunnel (đường hầm) |

Two candidate codes were **wrong on the metadata alone** and only the picture
caught it: `R412a` is "Lane for coaches" (not a turn sign) and `R411` is a
lane-direction board — neither belongs to `only_*`. Within the R.301 family the eye
had to choose: `R301b`/`R301c` draw a flat arrow, `R301d`/`R301e` the turning one,
so the turn kinds take `d`/`e`.

Still painted, deliberately:

* `speed` — the sign IS a white disc carrying the km/h, and the number comes from
  the data (`_SpeedPainter`).
* `tollBooth` — no QCVN sign for a toll plaza exists on Commons (its `I.428b/c`
  are EV and gas stations), so it keeps its text chip.
* `signal`, `reservedLane`, `no_straight`, `no_turn_both` — no source emits them
  today (OSM emits `signal` only); their painters stay as a guard.

`populated` / `populated_end` are NOT bundled: both kinds are dropped at load
(`droppedSignKinds`), so no artwork could ever be drawn.

## 2. The QCVN code on a kind is now the code of its PNG

The info sheet prints the kind's code, and three of them named a DIFFERENT sign
than the picture shown:

| kind | was | now | why |
|---|---|---|---|
| `no_passing` | P.127 cấm vượt | **P.125** | P.125 is the overtaking ban in both QCVN editions (Commons metadata) |
| `no_u_turn` | P.125 cấm quay đầu | **P.124a** | P.125 is the overtaking ban; the bundled art is the U-turn sign |
| `only_left/right/straight` | R.412a / R.412 / R.411 | **R.301e / R.301d / R.301a** | R.412a is "Lane for coaches", R.411 a lane-direction board |
| `no_passing_end` | (no code) | P.133 | Commons: "End of the overtaking prohibition" |
| `no_auto` | (no code) | P.103a | Commons |
| `one_way` | (no code) | I.407a | Commons |
| `railway_crossing` | (no code) | W.242a | Commons |
| `tunnel` | (no code) | W.240 | Commons |

`test/sign_icons_test.dart` pins both lists: every kind a source can emit must have
artwork, and every corrected code must keep its QCVN prefix.

## 3. One camera icon everywhere

New `lib/ui/camera_icon.dart` → `WazeCameraIcon` wraps
`assets/waze/icon_alerter_cam_speed.png` (with the CCTV glyph only as an
`errorBuilder` fallback). Now used by:

* `ui/vector_nav_map.dart` `_cameraMarker()` (navigation map — unchanged picture,
  now via the shared widget),
* `pages/navigation/modules/nav_map.dart` (browse/start map markers — replaced the
  CCTV-in-a-circle),
* the provenance dot that used to sit in the marker's corner was REMOVED as well
  (user: "why there is a dot near the camera"): next to the Waze icon it read as a
  second camera badge, the navigation marker has none, and the source
  (waze/police/osm/vietmap) is printed in the tap sheet, where the same coloured dot
  is now just a legend swatch,
* `overlay/overlay_main.dart` camera chips,
* `ui/overlay_layout_screen.dart` layout previews (were Material `videocam`),
* `nav_bars.dart` PiP camera pill and `nav_simple.dart` camera chip (were the 📷
  emoji).

## Verification

* `flutter analyze` — no issues; `flutter test` — **451 tests pass**.
* `tools/signs/sign_contact_sheet.py` — all 20 bundled PNGs map to the kind they
  are drawn for; nothing unused.
* Emulator (`emulator-5554`, release arm64 APK `30c66315…`, base.apk md5 matches):
  start map shows the Waze camera PNG markers (colour-profile probe: marker patches
  carry the icon's black + strong-blue, map control patches carry neither) and the
  sign PNGs (STOP octagons, the 60 km/h speed disc).
* The phone was NOT updated in this pass.
