/// When may an adopted speed-limit sign overrule the road's own posted limit?
///
/// Extracted from the navigation page so the rule can be unit-tested on its
/// own — the 09-18 trip failed it in a way that cost the whole drive its limit
/// (a 60 km/h sign belonging to Lũy Bán Bích was applied to Vườn Lài the car
/// was still on, 400 m early, and never released).
///
/// Two conditions, both required:
///
///  1. **Reached.** The app adopts a speed sign up to [kSignReachedM] metres
///     early so it can preview the limit and warn about a drop ahead — but a
///     sign ahead belongs to the road AHEAD. Letting it change the limit while
///     the car is still on the previous street is exactly how the sign for the
///     next street became the limit for the current one. Until the car is at
///     the sign the road's own value stands.
///
///  2. **Same road.** A sign only applies on the road it is posted on. When the
///     sign's road is unknown (it was adopted before the first road lookup),
///     the sign is trusted while the car is at it — the caller is expected to
///     re-bind the road as soon as a name is known, so it cannot outlive a
///     road change ([currentRoad] then differs and the sign is dropped).
library;

import 'road_match.dart';

/// A sign counts as "reached" within this distance along the route. Matches the
/// adoption window's own resolution: the app re-adopts the nearest sign within
/// [kSignAdoptM] and sets the distance to 0 once it is behind the car.
const double kSignReachedM = 50.0;

/// How many consecutive fixes a changed posted value must hold before it counts
/// as a step (a khu dân cư transition) — 2 s at 1 Hz.
///
/// Confirming by DISTANCE instead (300 m) was tried on 2026-10-25 and cost
/// recall badly: inside a town the value oscillates 50 ⇄ 60 well inside 300 m,
/// so the anchor kept resetting (towns covered fell 9/9 → 3/9).
const int kLayerStepConfirmFixes = 2;

/// Metres the NEW band (≤60 or ≥70) must hold before the step is believed.
///
/// This is the only evidence that separates a real village on a highway from a
/// junction where Waze's segments alternate 60/80 for four fixes: on the
/// 2026-10-26 drive the "flicker" spots were 60–120 m long (km 76,5 / 157,7 /
/// 167,4 / 168,5 — each announced "hết" then "bắt đầu" 100 m later), while every
/// real zone was 500 m or more. Counting fixes cannot tell them apart — both
/// last several fixes — but the metres can.
const double kZoneStepConfirmM = 150.0;

/// True when this road is LIMITED ACCESS — an expressway, its ramps, a toll
/// plaza, a slip road — where a low posted limit is the barrier, the ramp or
/// roadworks and never a built-up verdict.
///
/// Measured 2026-10-30 on a car drive down CT HCM–Long Thành–Dầu Giây: the Dầu
/// Giây toll plaza posts 60 on a WME class-3 segment and the app answered with
/// "Bắt đầu khu dân cư" at the barrier, then "Hết khu dân cư" 200 m later at
/// 120 km/h. The same drive's ramp ("Hầm chui > Cao tốc", class 4, 50 km/h) and
/// slip road ("> Dầu Giây", 60 km/h) did the same. [roadClass] is the WME
/// `roadType`: 3 = freeway, 4 = ramp.
bool isLimitedAccessRoad(String? name, {int roadClass = 0}) {
  if (roadClass == 3 || roadClass == 4) return true;
  final n = (name ?? '').trimLeft().toLowerCase();
  if (n.isEmpty) return false;
  return n.startsWith('>') ||
      n.startsWith('ct') ||
      n.contains('cao tốc') ||
      n.contains('thu phí') ||
      n.contains('expressway');
}

/// The "làn hỗn hợp" (mixed lane beside an expressway) shares its corridor with
/// the 80 km/h main carriageway, so switching between them must not move the
/// zone at all — measured 8 flips in 8 minutes on Mai Chí Thọ.
bool isMixedLane(String? name) =>
    (name ?? '').toLowerCase().contains('làn hỗn hợp');

/// How close two khu dân cư SENTENCES may be before the second one is dropped,
/// metres.
///
/// The state still follows the road (the statutory limit changes); only the
/// announcement is held. 300 m is below the shortest real built-up stretch
/// measured on these drives (500 m, and the 176 km run's closest genuine pair
/// was 366 m) and above every artifact seen so far:
///
///   * 2026-10-30, QL1/QL20 at 110 km/h: "Hết" and "Bắt đầu" logged 1 ms apart
///     (the same fix, two lookups disagreeing) and 180 m apart on the CT01
///     approach;
///   * 2026-10-30, Mai Chí Thọ: 8 flips in 8 minutes while changing between the
///     mixed lane (60) and the expressway carriageway (80).
const double kZoneMinGapM = 300.0;

/// How close an OPPOSITE khu dân cư transition may be to the one just
/// announced before it is treated as the other direction's plate / a flicker,
/// metres. Inside this window the announcement needs the posted LAYER to have
/// moved the same way (the segment layer is positionally exact); otherwise it is
/// blocked — see `_NavSigns._zoneFlipBlocked`.
///
/// 200 m, not 800: the WME layer really does carry short zones (a 700 m village
/// between two 80 km/h stretches on QL20). Measured 2026-10-26 — an 800 m guard
/// swallowed the entry at km 135,4 and the ones at 147,3 / 166,9 while the
/// villages were still there in the data.
const double kZoneFlipGuardM = 200.0;

/// How close the OPPOSITE prohibition may be to the one just announced before it
/// counts as the other carriageway's plate rather than a real change, metres.
///
/// CẤM VƯỢT is a kilometres-long ban; measured 2026-10-25, the pack put "cấm
/// vượt" at km 40,6 / 41,5 and "hết cấm vượt" at 42,2 on the same stretch, and
/// all three were announced inside 2 s.
const double kProhibitionFlipM = 1000.0;

/// How close a no-overtaking callout may be to a khu dân cư sentence, metres.
///
/// ⭐ Two sentences at one junction are heard as one. Measured 2026-10-29 (176 km
/// Bảo Lộc → Sài Gòn): three of the 14 prohibition callouts landed 45 / 52 /
/// 69 m from "Bắt đầu / Hết khu dân cư" — 3–5 s of driving at 50 km/h, i.e.
/// while the boundary sentence was still being spoken. The boundary wins (it
/// moves the statutory limit), so the prohibition is the one held; pairs 400 m
/// or more apart are ~30 s of driving and are kept.
const double kZoneProhibitionGapM = 200.0;

/// Should this no-overtaking plate stay SILENT?
///
/// Pure, so the policy the driver hears can be pinned by a test. Each rule was
/// bought with a measured defect (2026-10-25 / 2026-10-29 drives):
///
///  * [startsBan] `== bannedNow` — the pack repeats P.125 every couple of
///    kilometres along ONE ban, and posts ban + end at the same point, so
///    "cấm vượt" while it is already in force (or "hết cấm vượt" when no ban
///    was announced) tells the driver nothing.
///  * [oppositeNear] — the opposite plate a few hundred metres later is the
///    other carriageway's (see [kProhibitionFlipM]).
///  * [zoneNear] — a built-up boundary sentence was just spoken at this
///    junction, and the two must not overlap (see [kZoneProhibitionGapM]).
bool prohibitionSuppressed({
  required bool startsBan,
  required bool bannedNow,
  required bool oppositeNear,
  required bool zoneNear,
}) => zoneNear || oppositeNear || startsBan == bannedNow;

/// How far ahead of the car a speed sign is ADOPTED (becomes the preview
/// limit / the next-limit wording). Beyond this the sign is not looked at, so
/// the held value is treated as in force ([kSignReachedM]).
const double kSignAdoptM = 400.0;

/// How far ahead the sign scan looks — also the outer bound for the "giảm tốc
/// độ, giới hạn X phía trước" advance warning ([kSignAdoptM]..[kSignWarnM]).
const double kSignWarnM = 1000.0;

/// How close a red-light camera must be to a traffic-light sign for the two to
/// describe the SAME junction. The camera alert is more informative (it names
/// the source and the distance), so the sign callout is dropped inside this
/// window instead of saying "đèn đỏ/đèn giao thông" twice.
const double kJunctionCameraToleranceM = 150.0;

/// True when [cameraMeters] is a red-light camera at the same junction as a
/// traffic-light sign [signMeters] ahead of the car.
///
/// Both distances are ALONG THE ROUTE from the car. A missing camera, a
/// non-red-light camera, or a camera farther than [toleranceM] from the sign
/// returns false (the light keeps its own callout).
bool redLightCameraCoversJunction({
  required double signMeters,
  required double? cameraMeters,
  required bool isRedLightCamera,
  double toleranceM = kJunctionCameraToleranceM,
}) {
  if (!isRedLightCamera || cameraMeters == null) return false;
  return (cameraMeters - signMeters).abs() <= toleranceM;
}

/// True when the adopted sign ([signValue]) is IN FORCE — not merely previewed.
///
/// [layerKmh] is the posted limit the SEGMENT layer under the car carries
/// (0 = unknown). When it is known, the sign may only TIGHTEN it, never raise
/// it: on the 2026-09-20 drive three real VietMap 60 signs standing on Lũy Bán
/// Bích (141-340 m away, their own segment says 60) were applied to Tân Thành
/// and Vườn Lài, whose segment says 50 — 166 fixes of the chip reading 60 on a
/// 50 street. A stricter sign (a genuine 40 in a school zone) still applies.
bool signLimitInForce({
  required int? signValue,
  required double signAheadM,
  required String? signRoad,
  required String? currentRoad,
  int layerKmh = 0,
}) {
  if (signValue == null || signValue <= 0) return false;
  // 1. not there yet → the road's own limit still stands
  if (signAheadM > kSignReachedM) return false;
  // 2. the segment layer is authority → a sign may only tighten it
  if (layerKmh > 0 && signValue > layerKmh) return false;
  // 3. posted on another road → not ours
  if (signRoad == null || signRoad.isEmpty) return true;
  return currentRoad != null && sameRoad(signRoad, currentRoad);
}
