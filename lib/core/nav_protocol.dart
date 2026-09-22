/// Navigation maneuvers, icon codes, symbols and Vietnamese guidance formatters.
///
/// Icon codes:
///   1=straight, 2=turn-left, 3=turn-right, 4=slight-left, 5=slight-right,
///   6=uturn-left, 7=uturn-right, 8=roundabout, 9=arrive, 0=unknown
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const int iconUnknown = 0;
const int iconStraight = 1;
const int iconTurnLeft = 2;
const int iconTurnRight = 3;
const int iconSlightLeft = 4;
const int iconSlightRight = 5;
const int iconUturnLeft = 6;
const int iconUturnRight = 7;
const int iconRoundabout = 8;
const int iconArrive = 9;

const Map<int, String> iconNames = {
  iconUnknown: 'unknown',
  iconStraight: 'straight',
  iconTurnLeft: 'turn-left',
  iconTurnRight: 'turn-right',
  iconSlightLeft: 'slight-left',
  iconSlightRight: 'slight-right',
  iconUturnLeft: 'uturn-left',
  iconUturnRight: 'uturn-right',
  iconRoundabout: 'roundabout',
  iconArrive: 'arrive',
};

/// A compact arrow symbol for an [iconCode] — used by notifications and the
/// ESP banner text. '←' left, '→' right, '↑' straight, '↖' slight left,
/// '↗' slight right, '↩' u-turn.
String iconSymbol(int iconCode) => switch (iconCode) {
  iconTurnLeft => '←',
  iconTurnRight => '→',
  iconSlightLeft => '↖',
  iconSlightRight => '↗',
  iconUturnLeft || iconUturnRight => '↩',
  iconRoundabout => '↻',
  iconArrive => '⛳',
  _ => '↑', // straight / unknown
};

/// GraphHopper / VietMap instruction `sign` → OSRM-style (type, modifier).
///
/// The sign numbers are GraphHopper's own constants, verified against
/// `com.graphhopper.util.Instruction`: -98 U_TURN_UNKNOWN, -8 U_TURN_LEFT,
/// -7 KEEP_LEFT, -6 ROUNDABOUT_EXIT, -3..-1 sharp/left/slight left,
/// 0 CONTINUE_ON_STREET, 1..3 slight/right/sharp right, 4 FINISH,
/// 5 REACHED_VIA, 6 ROUNDABOUT_USE, 7 **KEEP_RIGHT**, 8 U_TURN_RIGHT, 9 FERRY.
/// VietMap's route v4 uses the same family (its response is GraphHopper-shaped).
///
/// ⭐ 7 is KEEP_RIGHT, not a roundabout. Both routers had `6 || 7 => roundabout`,
/// so every keep-right fork on the offline graph announced "đi theo vòng xuyến"
/// (follow the roundabout) at a place with no roundabout. The two codes that had
/// no case at all — -7 (keep left) and -6 (leaving the roundabout) — fell through
/// to "đi thẳng", i.e. the app invited the driver to drive straight past the
/// roundabout exit they were meant to take.
(String, String?) osrmManeuverForInstructionSign(int sign) => switch (sign) {
  // U-turn left / unknown / right — all three are "quay đầu" (the icon has no
  // side that matters to the driver, and the voice says the same word).
  -98 || -8 || 8 => ('turn', 'uturn'),
  -7 => ('fork', 'slight left'),
  -6 => ('roundabout', 'left'),
  -3 => ('turn', 'sharp left'),
  -2 => ('turn', 'left'),
  -1 => ('turn', 'slight left'),
  0 => ('continue', 'straight'),
  1 => ('turn', 'slight right'),
  2 => ('turn', 'right'),
  3 => ('turn', 'sharp right'),
  6 => ('roundabout', 'left'),
  7 => ('fork', 'slight right'),
  9 => ('ferry', null),
  4 || 5 => ('arrive', null),
  _ => ('continue', 'straight'),
};

/// Map a Vietmap navigation maneuver (modifierType + modifier) to the clock
/// icon code. Same vocabulary as OSRM/Mapbox: type=turn, modifier=left, ...
int iconForManeuver(String? type, String? modifier) {
  final t = (type ?? '').toLowerCase().replaceAll(' ', '');
  final m = (modifier ?? '').toLowerCase().replaceAll(' ', '');

  if (t == 'arrive') return iconArrive;
  if (t == 'roundabout' ||
      t == 'rotary' ||
      t == 'roundaboutturn' ||
      t == 'exitroundabout' ||
      t == 'exitrotary') {
    return iconRoundabout;
  }
  if (t == 'uturn' || m == 'uturn') {
    return (m == 'left' || m == 'uturn') ? iconUturnLeft : iconUturnRight;
  }
  if (m == 'left' || m == 'sharpleft') return iconTurnLeft;
  if (m == 'right' || m == 'sharpright') return iconTurnRight;
  if (m == 'slightleft') return iconSlightLeft;
  if (m == 'slightright') return iconSlightRight;
  return iconStraight; // depart / continue / new name / merge / ...
}

/// ETA as (hour, minute) from the remaining seconds until arrival.
(int, int) etaFromRemaining(double remainingSeconds) {
  final now = DateTime.now();
  if (!remainingSeconds.isFinite || remainingSeconds <= 0) {
    return (now.hour, now.minute);
  }
  final totalMin =
      (now.hour * 60 + now.minute + (remainingSeconds / 60).round()) % 1440;
  return ((totalMin ~/ 60) % 24, totalMin % 60);
}

/// '450 m' / '1,2 km' — Vietnamese style, like the official app.
String formatDistance(num meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  return '${meters.round()} m';
}

/// Spoken Vietnamese distance — "450 mét" / "1,2 km" — so TTS says a natural
/// unit: meters under 1 km, kilometres above (the UI card already uses
/// [formatDistance], the voice now matches it).
String formatDistanceSpoken(num meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  return '${meters.round()} mét';
}

/// Vietnamese guidance verb for an icon code ("rẽ trái", "đi thẳng", …).
/// Shared by the spoken announcements and the on-screen Vietmap-style banner.
String maneuverVerb(int code) => switch (code) {
  iconTurnLeft => 'rẽ trái',
  iconTurnRight => 'rẽ phải',
  iconSlightLeft => 'rẽ trái nhẹ',
  iconSlightRight => 'rẽ phải nhẹ',
  iconUturnLeft || iconUturnRight => 'quay đầu',
  iconRoundabout => 'đi theo vòng xuyến',
  iconArrive => 'đến nơi',
  _ => 'đi thẳng',
};

// ---------------------------------------------------------------------------
// Turn-direction cross-check against the route GEOMETRY
// ---------------------------------------------------------------------------
//
// The routers hand us a left/right LABEL per step (`modifier`), and the whole
// guidance chain (voice verb, banner arrow, ESP32 maneuver packet) repeats it
// verbatim. That label is not always what the road does: at angled Vietnamese
// junctions, alley mouths and split carriageways a step gets labelled right
// while its own polyline turns left. Audited over 30 recorded callouts anchored
// on the street each one named, 4 disagreed with the driven path, all of them
// "said right / went left" — e.g. "rẽ phải vào Tân Thành" where the route
// swings −80°.
//
// The geometry is the path the driver is about to actually drive, so it is the
// better authority for the DIRECTION. We only let it overrule the label inside
// the lateral family (slight/left/right): U-turn and roundabout steps are
// structural (a deliberate U-turn on a dual carriageway often swings only ~90°,
// and a roundabout's own geometry is a circle), so those keep the router's word.

/// [geometry] turn angle in degrees at [point]: positive = right (clockwise),
/// negative = left. Chord bearings are taken [spanM] of polyline either side of
/// the closest vertex, so a single tiny segment at the vertex can't dominate.
/// Null when [point] can't be placed, or there isn't enough polyline on BOTH
/// sides (route start/end).
double? routeTurnDegrees(
  List<LatLng> geometry,
  LatLng point, {
  double spanM = 45,
}) {
  if (geometry.length < 3) return null;
  var vi = -1;
  var best = double.infinity;
  for (var i = 0; i < geometry.length; i++) {
    final d = _meters(geometry[i], point);
    if (d < best) {
      best = d;
      vi = i;
    }
  }
  if (vi <= 0 || vi >= geometry.length - 1) return null;

  var backM = 0.0;
  var bi = vi;
  while (bi > 0 && backM < spanM) {
    backM += _meters(geometry[bi - 1], geometry[bi]);
    bi--;
  }
  var fwdM = 0.0;
  var fi = vi;
  while (fi < geometry.length - 1 && fwdM < spanM) {
    fwdM += _meters(geometry[fi], geometry[fi + 1]);
    fi++;
  }
  // Need a real chord on both sides, else the angle is noise.
  if (backM < spanM * 0.5 || fwdM < spanM * 0.5) return null;

  final b1 = _bearing(geometry[bi], geometry[vi]);
  final b2 = _bearing(geometry[vi], geometry[fi]);
  return (b2 - b1 + 540) % 360 - 180;
}

/// The icon code the route geometry supports at [point], given the router's
/// [fallback] code. Returns [fallback] whenever the geometry can't decide
/// (no point, too little polyline, a near-straight or U-turn-sized angle) or
/// the label is not a lateral turn.
int refineManeuverIcon(List<LatLng> geometry, LatLng? point, int fallback) {
  const lateral = {
    iconSlightLeft,
    iconSlightRight,
    iconTurnLeft,
    iconTurnRight,
  };
  if (point == null || !lateral.contains(fallback)) return fallback;
  final deg = routeTurnDegrees(geometry, point);
  if (deg == null) return fallback;
  final a = deg.abs();
  // < 18° the geometry itself is uncertain; >= 135° is U-turn shaped, and a
  // U-turn is not a left/right we should invent from an angle.
  if (a < 18 || a >= 135) return fallback;
  if (deg > 0) return a >= 45 ? iconTurnRight : iconSlightRight;
  return a >= 45 ? iconTurnLeft : iconSlightLeft;
}

double _meters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final p1 = a.latitude * math.pi / 180;
  final p2 = b.latitude * math.pi / 180;
  final dp = (b.latitude - a.latitude) * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

double _bearing(LatLng a, LatLng b) {
  final p1 = a.latitude * math.pi / 180;
  final p2 = b.latitude * math.pi / 180;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
