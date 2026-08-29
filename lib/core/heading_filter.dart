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
  double? update(double? rawHeading, LatLng pos) {
    final travel = _headingBetween(_lastFix, pos);
    _lastFix = pos;
    double? result;
    if (travel == null) {
      // No reliable direction of travel (stationary / sub-2 m jitter): keep
      // the last heading. Only seed once from the compass on the very first
      // fix so a parked arrow still points somewhere before the car moves.
      result =
          heading ??
          ((rawHeading != null && !rawHeading.isNaN) ? rawHeading : null);
    } else {
      final candidate = travel;
      final prev = heading;
      if (prev == null) {
        result = candidate; // first fix — accept
      } else {
        final delta = _angDiff(candidate, prev);
        if (delta <= 40) {
          _pending = null;
          _pendingAt = null;
          result = candidate; // normal turn — trust it
        } else {
          // Large jump → require a second, agreeing fix SOON after.
          final now = DateTime.now();
          if (_pending != null &&
              _pendingAt != null &&
              now.difference(_pendingAt!) < const Duration(seconds: 3) &&
              _angDiff(candidate, _pending!) <= 40) {
            _pending = null;
            _pendingAt = null;
            result = candidate; // two consecutive fixes agree → apply
          } else {
            _pending = candidate; // remember for the next fix
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
