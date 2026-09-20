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

/// A sign counts as "reached" within this distance along the route. Matches the
/// adoption window's own resolution: the app re-adopts the nearest sign within
/// [kSignAdoptM] and sets the distance to 0 once it is behind the car.
const double kSignReachedM = 50.0;

/// How far ahead of the car a speed sign is ADOPTED (becomes the preview
/// limit / the next-limit wording). Beyond this the sign is not looked at, so
/// the held value is treated as in force ([kSignReachedM]).
const double kSignAdoptM = 400.0;

/// How far ahead the sign scan looks — also the outer bound for the "giảm tốc
/// độ, giới hạn X phía trước" advance warning ([kSignAdoptM]..[kSignWarnM]).
const double kSignWarnM = 1000.0;

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
  return signRoad == currentRoad;
}
