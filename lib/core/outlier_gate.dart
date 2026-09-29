/// Outlier gate for raw GPS fixes — an "innovation gate" like Google/Mapbox.
///
/// Real navigation software doesn't trust every raw fix. It rejects fixes that
/// are (a) too inaccurate, or (b) a position jump that is physically
/// inconsistent with the recent smoothed speed (the Kalman innovation gate,
/// approximated here with a simple complementary prior):
///
///   - accuracy > 35 m                              → reject
///   - jump > max(3 × smoothedSpeed × dt, 25 m)     → reject
///
/// `smoothedSpeed` is an EMA of the MEASURED (accepted) fix-to-fix speed, so a
/// single GPS burst (position AND speed both wrong, e.g. a 130 km/h reading)
/// is rejected — while a large movement over a real GPS gap (dt large) is
/// kept, because the allowed jump scales with dt.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/settings.dart' show gpsFilterStrength;

class OutlierGate {
  /// EMA weight for the smoothed speed (fast enough to follow, slow enough to
  /// not spike on one bad fix).
  static const double _speedAlpha = 0.5;

  /// Minimum plausible speed used by the jump gate (m/s ≈ 18 km/h). The
  /// allowed jump scales with dt AND at least this speed, so a large movement
  /// over a real GPS gap (dt large) is kept even when the smoothed speed is
  /// still low, while a short-interval burst is still rejected.
  static const double _minPlausibleMps = 5.0;

  /// Fixes worse than this are dropped outright (set per strength).
  double _maxAccuracyM = 35.0;

  /// How many times the (floored) speed a jump may exceed before it's rejected
  /// (set per strength).
  double _jumpFactor = 3.0;

  double _smoothSpeedMps = 0.0;
  LatLng? _lastFix;

  /// Re-apply thresholds from the persisted strength ('light' | 'standard' |
  /// 'strong'). Called on construction and again per-fix so a settings change
  /// takes effect immediately on the next GPS fix.
  void _applyStrength(String? s) {
    switch (s) {
      case 'light':
        _maxAccuracyM = 50.0;
        _jumpFactor = 4.0;
      case 'strong':
        _maxAccuracyM = 25.0;
        _jumpFactor = 2.2;
      default: // 'standard'
        _maxAccuracyM = 35.0;
        _jumpFactor = 3.0;
    }
  }

  /// Smoothed speed (EMA of accepted fix-to-fix speed), m/s — the prior the
  /// jump gate compares against.
  double get smoothSpeedMps => _smoothSpeedMps;

  /// Diagnostics.
  int accepted = 0;
  int rejected = 0;

  /// Returns true to ACCEPT [pos]; false rejects the outlier. [dt] = seconds
  /// since the last ACCEPTED fix (null on the first fix).
  ///
  /// [speedMps] is the fix's OWN reported speed. It is used only to seed the
  /// prior on a cold start: with no accepted fix yet the prior is 0, the jump
  /// floor is [OutlierGate._minPlausibleMps] × dt × factor (15 m at 1 s ≈
  /// 54 km/h), and a drive that begins ALREADY MOVING is therefore rejected —
  /// and because the EMA above only updates on accepted fixes, every later fix
  /// is rejected too: the gate never recovers and the app shows nothing at all.
  /// Measured on the long-trip replay (2026-09-27): `GPS: REJECTED dt=0.94s`
  /// then `1.88s`, `2.82s` … for the whole run, while the car was doing 76 km/h
  /// down QL1A. Real cases: the app opened while riding, or a replay resumed
  /// mid-route with `?from=`.
  bool accept(
    LatLng pos, {
    double? accuracy,
    double? dt,
    double? speedMps,
  }) {
    // Reflect the persisted GPS-filter strength on every fix so a settings
    // change applies without restarting navigation.
    _applyStrength(gpsFilterStrength);
    if (accuracy != null && accuracy > _maxAccuracyM) {
      rejected++;
      return false;
    }
    // Cold start: believe the fix's own speed rather than assuming the car is
    // standing still. Only until the first fix is accepted — from then on the
    // measured EMA (which a bad reading cannot move) is the prior again.
    if (accepted == 0 &&
        speedMps != null &&
        speedMps.isFinite &&
        speedMps > _minPlausibleMps) {
      _smoothSpeedMps = speedMps;
    }
    final prev = _lastFix;
    if (prev != null && dt != null && dt > 0) {
      final d = _meters(prev, pos);
      // Allowed jump scales with the time gap: a 90 m move over an 8 s GPS
      // gap is normal, a 34 m move in 1 s is a burst. The floored speed keeps
      // legitimate movement accepted even before the EMA has caught up.
      final allowed =
          math.max(_smoothSpeedMps, _minPlausibleMps) * dt * _jumpFactor;
      if (d > allowed) {
        rejected++;
        return false; // jump inconsistent with the recent speed
      }
      final implied = d / dt;
      _smoothSpeedMps =
          _speedAlpha * implied + (1 - _speedAlpha) * _smoothSpeedMps;
    }
    _lastFix = pos;
    accepted++;
    return true;
  }

  static double _meters(LatLng a, LatLng b) {
    final mPerDegLat = 111320.0;
    final mPerDegLng = mPerDegLat * math.cos(a.latitude * math.pi / 180);
    final dLat = (b.latitude - a.latitude) * mPerDegLat;
    final dLng = (b.longitude - a.longitude) * mPerDegLng;
    return math.sqrt(dLat * dLat + dLng * dLng);
  }
}
