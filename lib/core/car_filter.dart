/// Complementary filter for the car's position + speed + heading.
///
/// The map always receives the position SNAPPED to the route (the navigation
/// engine projects every GPS fix onto the route polyline), so we assume the
/// car is always on the route. This filter therefore just:
///   1. smooths the speed estimate (low-pass — fixes the jumpy finite-
///      difference "last two fixes / time" estimate that made the car lurch),
///   2. follows the engine's smoothed route bearing for the dead-reckon
///      direction (never the noisy raw GPS heading),
///   3. glides the car between the ~1 Hz GPS fixes (dead-reckoning), then
///      fuses the next fix back in (complementary: trust the fix long-term,
///      trust the glide short-term).
///
/// This is deliberately a few dozen lines — no full 4-state Kalman machinery,
/// which was overkill here and (with an untuned prior) converged far too
/// slowly to glide correctly from a standstill.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class CarFilter {
  /// How much a new GPS speed measurement is trusted (0..1). 0.3 = strong
  /// smoothing — a single jittery fix barely moves the estimate.
  static const double _speedAlpha = 0.3;

  /// How much the new route bearing is trusted (0..1). The engine bearing is
  /// already smoothed, so a modest alpha just prevents a hard snap on route
  /// changes.
  static const double _bearingAlpha = 0.4;

  /// How much the fresh GPS fix is trusted over the dead-reckoned glide
  /// (0..1). High = stays glued to the route (we assume on-route anyway).
  static const double _posAlpha = 0.8;

  double _speedMps = 0;
  double _bearingDeg = 0;
  bool _hasBearing = false;
  LatLng? _pos;
  LatLng? _prevFix;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Smoothed speed, m/s.
  double get speedMps => _speedMps;

  /// Smoothed heading, degrees (0 = north, clockwise).
  double get bearing => _bearingDeg;

  /// Current fused position.
  LatLng get position => _pos ?? const LatLng(0, 0);

  bool get initialized => _pos != null;

  /// Feed a GPS fix (already snapped to the route). [dt] = seconds since the
  /// last fix (falls back to the wall clock). [routeBearing] = the engine's
  /// smoothed route-ahead bearing (null = unknown) — the dead-reckon direction.
  void update(LatLng fix, {double? dt, double? routeBearing}) {
    final now = DateTime.now();
    final d =
        dt ??
        (_lastAt.millisecondsSinceEpoch == 0
            ? 0.0
            : now.difference(_lastAt).inMilliseconds / 1000.0);
    _lastAt = now;

    final prev = _prevFix;
    if (prev != null && d > 0) {
      // Low-pass the speed: measured distance since the last fix / time.
      final measured = _distMeters(prev, fix) / d;
      _speedMps = _speedAlpha * measured + (1 - _speedAlpha) * _speedMps;
    } else {
      _speedMps = 0;
    }

    // Heading: follow the route bearing when available, otherwise the fix-
    // to-fix travel bearing; low-passed so it never snaps.
    double newBearing;
    if (routeBearing != null) {
      newBearing = (routeBearing % 360 + 360) % 360;
    } else if (prev != null && _distMeters(prev, fix) > 0.5) {
      newBearing = _bearingBetween(prev, fix);
    } else {
      newBearing = _hasBearing ? _bearingDeg : 0;
    }
    if (_hasBearing) {
      _bearingDeg = _slerpBearing(_bearingDeg, newBearing, _bearingAlpha);
    } else {
      _bearingDeg = newBearing;
      _hasBearing = true;
    }

    // Complementary fusion: glide from where we were, then pull toward the
    // fresh fix (which is on the route, so it dominates).
    if (_pos != null && d > 0 && d < 1.0 && _speedMps > 0.3) {
      final glided = _advance(_pos!, _bearingDeg, _speedMps * d);
      _pos = LatLng(
        _posAlpha * fix.latitude + (1 - _posAlpha) * glided.latitude,
        _posAlpha * fix.longitude + (1 - _posAlpha) * glided.longitude,
      );
    } else {
      _pos = fix;
    }
    _prevFix = fix;
  }

  /// Dead-reckon [dt] seconds forward along the smoothed heading at the
  /// smoothed speed (called on every camera frame between fixes).
  LatLng predict(double dt) {
    final p = _pos;
    if (p == null || dt <= 0 || _speedMps <= 0.3) {
      return p ?? const LatLng(0, 0);
    }
    final next = _advance(p, _bearingDeg, _speedMps * dt);
    _pos = next;
    return next;
  }

  /// Pin the filter's position to [p] (e.g. the route-snapped point) WITHOUT
  /// touching the smoothed speed/heading — the next dead-reckon then starts
  /// FROM the road, so a corner-cutting glide is corrected immediately.
  void snapTo(LatLng p) => _pos = p;

  static LatLng _advance(LatLng from, double bearingDeg, double distM) {
    final rad = bearingDeg * math.pi / 180;
    final lat = from.latitude + distM * math.cos(rad) / 111320.0;
    final lng =
        from.longitude +
        distM *
            math.sin(rad) /
            (111320.0 * math.cos(from.latitude * math.pi / 180));
    return LatLng(lat, lng);
  }

  static double _distMeters(LatLng a, LatLng b) {
    final dy = (b.latitude - a.latitude) * 111320.0;
    final dx =
        (b.longitude - a.longitude) *
        111320.0 *
        math.cos(a.latitude * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _bearingBetween(LatLng a, LatLng b) {
    final y =
        math.sin((b.longitude - a.longitude) * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180);
    final x =
        math.cos(a.latitude * math.pi / 180) *
            math.sin(b.latitude * math.pi / 180) -
        math.sin(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.cos((b.longitude - a.longitude) * math.pi / 180);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Interpolate an angle toward [target] by [alpha] (0..1), handling the
  /// 359°→0° wrap.
  static double _slerpBearing(double from, double to, double alpha) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return (from + d * alpha + 360) % 360;
  }
}
