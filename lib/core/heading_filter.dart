/// Strict, GPS-heading filter for the car arrow.
///
/// Small changes (normal turning, ≤40°) apply at once; a BIG change — including
/// the classic ~180° GPS/magnetometer flip when slow or parked — is applied
/// only after TWO CONSECUTIVE fixes agree within ~3 s, so a single noisy fix
/// can never spin the arrow.
///
/// The filter prefers the TRUE direction of TRAVEL (bearing between the last
/// two fixes), which is stable and independent of the phone's magnetometer.
/// When the car hasn't moved enough to compute one (<2 m) it HOLDS the current
/// heading — the compass (`getBearing`) alternates ~0↔180° while parked, so
/// trusting it there spins the arrow in place. The compass is used only once,
/// to seed the very first heading before the car moves.
///
/// ⭐ `preferPhone` (Settings → Dẫn đường → "Nguồn hướng") inverts the
/// preference: the heading the RECEIVER reports each fix wins, and the travel
/// bearing is only the fallback. Same big-jump guard either way. Nothing in the
/// app reads the phone's magnetometer — `rawHeading` is the GNSS/fused bearing
/// that arrives with the fix.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class StrictHeading {
  /// Current filtered heading, degrees (0 = north, clockwise). Null until the
  /// first usable fix.
  double? heading;

  double? _pending;
  DateTime? _pendingAt;
  LatLng? _lastFix;

  /// Feed a raw heading (e.g. Android FusedLocation `getBearing`, may be NaN)
  /// plus the current GPS position; returns the filtered heading to display.
  ///
  /// [preferPhone] uses the heading the RECEIVER reports for this fix instead of
  /// the bearing between the last two fixes (see [headingSource] in
  /// `core/settings.dart`). The travel bearing needs two fixes more than 2 m
  /// apart, so in stop-and-go traffic it is either held from long ago or built
  /// from sub-2 m jitter — which is exactly where the posted-limit segment layer
  /// needs the direction (its `fwd`/`rev` pick and the "is the car riding this
  /// segment" test are both heading-based). The receiver's own bearing is
  /// available below that threshold. The big-jump guard below still applies, so
  /// one bad sample cannot spin the arrow either way.
  double? update(double? rawHeading, LatLng pos, {bool preferPhone = false}) {
    // A receiver with no bearing reports 0 (Android's convention), and the nav
    // code reads `_heading == 0` as "unknown" (`_heading == 0 ? null : _heading`
    // at four call sites). Treat it as unknown HERE too: otherwise a parked
    // phone seeds 0, `preferPhone` then holds the arrow on 0 forever, and the
    // posted-limit lookup silently loses the direction it needs — while a
    // genuine due-north heading is indistinguishable from that 0 anyway.
    final raw = (rawHeading != null && !rawHeading.isNaN && rawHeading != 0)
        ? rawHeading
        : null;
    final travel = _headingBetween(_lastFix, pos);
    _lastFix = pos;
    // The candidate to trust this fix: the phone's own heading, or the direction
    // of travel. Either may be unavailable — then the other stands in.
    final candidate = preferPhone ? (raw ?? travel) : travel;
    double? result;
    if (candidate == null) {
      // No reliable direction of travel (stationary / sub-2 m jitter): keep
      // the last heading. Only seed once from the compass on the very first
      // fix so a parked arrow still points somewhere before the car moves.
      result = heading ?? raw;
    } else {
      final candidateDir = candidate;
      final prev = heading;
      if (prev == null) {
        result = candidateDir; // first fix — accept
      } else {
        final delta = _angDiff(candidateDir, prev);
        if (delta <= 40) {
          _pending = null;
          _pendingAt = null;
          result = candidateDir; // normal turn — trust it
        } else {
          // Large jump → require a second, agreeing fix SOON after.
          final now = DateTime.now();
          if (_pending != null &&
              _pendingAt != null &&
              now.difference(_pendingAt!) < const Duration(seconds: 3) &&
              _angDiff(candidateDir, _pending!) <= 40) {
            _pending = null;
            _pendingAt = null;
            result = candidateDir; // two consecutive fixes agree → apply
          } else {
            _pending = candidateDir; // remember for the next fix
            _pendingAt = now;
            result = prev; // keep the current heading for now
          }
        }
      }
    }
    heading = result;
    return result;
  }

  /// Angular difference between two headings, 0–180°.
  double _angDiff(double a, double b) {
    var d = (a - b) % 360;
    if (d < 0) d += 360;
    return d > 180 ? 360 - d : d;
  }

  /// Great-circle bearing from [from] to [to] (deg, 0=N), or null when they
  /// haven't moved (GPS heading is undefined when standing still).
  double? _headingBetween(LatLng? from, LatLng to) {
    if (from == null) return null;
    final la1 = from.latitude * math.pi / 180;
    final dLat = (to.latitude - from.latitude) * 111320.0;
    final dLng = (to.longitude - from.longitude) * 111320.0 * math.cos(la1);
    if (math.sqrt(dLat * dLat + dLng * dLng) < 2.0) return null;
    final la2 = to.latitude * math.pi / 180;
    final dlng = (to.longitude - from.longitude) * math.pi / 180;
    final y = math.sin(dlng) * math.cos(la2);
    final x =
        math.cos(la1) * math.sin(la2) -
        math.sin(la1) * math.cos(la2) * math.cos(dlng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}
