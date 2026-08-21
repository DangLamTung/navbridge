/// A real-world 4-state constant-velocity Kalman filter for GPS location,
/// modelled on the standard ENU implementation used by open GPS filters
/// (e.g. `kalmanjs` / `gps-kalman-filter`).
///
/// State: `[east, north, vE, vN]` in metres around a local origin (the first
/// fix). Runs predict/correct on every GPS fix; between fixes call [predict]
/// to dead-reckon the camera glide. When the raw fixes show the car is
/// stopped, the velocity estimate is zeroed adaptively so GPS jitter is never
/// integrated into a drift (the classic "the dot crawls when parked" fix); a
/// moving car keeps its learned velocity, so it never lags.
///
/// Why ENU metres instead of degrees: latitude/longitude are not isotropic,
/// so the filter runs in a local east/north frame where distances are real
/// metres and the Kalman math is clean; the output is converted back to
/// lat/lng around the reference origin.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class LocationKalman {
  LocationKalman({
    /// Acceleration process noise (m/s²)² — how fast the filter thinks the
    /// car can accelerate. Larger = trusts GPS more (follows quicker).
    double processNoise = 4.0,

    /// GPS position measurement variance (m²) — the default trust in a fix.
    /// ~6 m urban GPS → 36 m².
    double measurementNoise = 36.0,
  }) : _q = processNoise,
       _sigma2 = measurementNoise;

  final double _q;
  final double _sigma2;

  // Reference (local ENU origin) = the first fix.
  double _refLat = 0, _refLng = 0;
  bool _initialized = false;

  // State: [east, north, vE, vN] (metres, m/s).
  final List<double> _x = List.filled(4, 0);
  // Covariance 4x4, row-major.
  final List<double> _cov = List.filled(16, 0);
  int _lastAtMs = 0;
  LatLng? _pos;
  LatLng? _prevFix;
  double _lastBearing = 0;

  /// Filtered position (lat/lng).
  LatLng? get position => _pos;

  /// Filtered speed, m/s.
  double get speedMps {
    final vE = _x[2], vN = _x[3];
    return math.sqrt(vE * vE + vN * vN);
  }

  /// Filtered heading, degrees (0 = north, clockwise). Holds the last
  /// heading when stopped so the arrow doesn't spin.
  double get bearing {
    if (speedMps < 0.3) return _lastBearing;
    final b = (math.atan2(_x[2], _x[3]) * 180 / math.pi + 360) % 360;
    _lastBearing = b;
    return b;
  }

  /// Feed a GPS fix. [accuracy] (metres) optionally scales the measurement
  /// noise — a clean fix is trusted more. [speedMps] optionally fuses the
  /// receiver's own speed measurement, an independent second channel whose
  /// noise σ = [speedNoise] m/s (the "speed noise"); it sharpens the velocity
  /// estimate without needing a compass. [nowMs] lets tests control time.
  void update(
    LatLng fix, {
    double? accuracy,
    double? speedMps,
    double speedNoise = 2.0,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!_initialized) {
      _refLat = fix.latitude;
      _refLng = fix.longitude;
      _x[0] = 0;
      _x[1] = 0;
      _x[2] = 0;
      _x[3] = 0;
      // Initial covariance: position ~10 m, velocity ~10 m/s (learned from
      // the first few fixes — this fast init is what made the old filter
      // "converge too slowly").
      _cov
        ..[0] = 100
        ..[1] = 0
        ..[2] = 0
        ..[3] = 0
        ..[4] = 0
        ..[5] = 100
        ..[6] = 0
        ..[7] = 0
        ..[8] = 0
        ..[9] = 0
        ..[10] = 100
        ..[11] = 0
        ..[12] = 0
        ..[13] = 0
        ..[14] = 0
        ..[15] = 100;
      _lastAtMs = now;
      _initialized = true;
      _pos = fix;
      return;
    }
    final dt = (now - _lastAtMs) / 1000.0;
    if (dt > 0) _predict(dt);
    // Adaptive anti-drift: the car is STOPPED when the receiver's speed
    // channel says so (the most reliable "at rest" signal — GPS speed is far
    // steadier than position at a standstill, so it doubles as the movement
    // detector) OR the raw positions aren't moving. Either way, zero the
    // velocity so GPS jitter is never integrated into a crawl (and the arrow
    // doesn't spin at rest). A moving car keeps its learned velocity (no lag).
    final prev = _prevFix;
    if (prev != null && dt > 0) {
      final a = _toEnu(prev);
      final b = _toEnu(fix);
      final moved = math.sqrt(
        (b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]),
      );
      if (moved / dt < 2.0 || (speedMps != null && speedMps < 2.0)) {
        _x[2] = 0;
        _x[3] = 0;
      }
    }
    _prevFix = fix;
    final z = _toEnu(fix);
    final sig = (accuracy != null && accuracy > 1.5)
        ? accuracy
        : math.sqrt(_sigma2);
    _correct(z, sig * sig);
    // Fuse the receiver's speed measurement (its own noise channel) — a
    // 1-D update on the velocity magnitude along the current heading.
    if (speedMps != null && speedMps.isFinite) {
      _correctSpeed(speedMps, speedNoise * speedNoise);
    }
    _lastAtMs = now;
    _pos = _fromEnu(_x[0], _x[1]);
  }

  /// Dead-reckon [dtS] seconds forward (between fixes, ~30 fps). Advances the
  /// state; the next [update]'s measurement correct pulls it back to the fix.
  /// [nowMs] lets tests control time.
  LatLng predict(double dtS, {int? nowMs}) {
    if (!_initialized || dtS <= 0) return _pos ?? const LatLng(0, 0);
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _predict(dtS);
    _lastAtMs = now;
    _pos = _fromEnu(_x[0], _x[1]);
    return _pos!;
  }

  /// Pin the filter's position state to [p] WITHOUT touching the velocity
  /// estimate. Used by the nav map to keep the dead-reckoned position riding
  /// the road between fixes — the filter still smooths speed/direction, but
  /// the position can no longer accumulate off-road error at corners (the
  /// Google-style "puck rides the road" behavior).
  void snapTo(LatLng p) {
    final e = _toEnu(p);
    _x[0] = e[0];
    _x[1] = e[1];
    _pos = p;
  }

  /// Constant-velocity prediction (no exponential damping — anti-drift is
  /// handled adaptively in [update] when the car is stopped, so a moving car
  /// never lags).
  void _predict(double dt) {
    final v = 1.0; // pure constant-velocity
    // State: pos += v·dt, velocity unchanged.
    _x[0] += dt * _x[2];
    _x[1] += dt * _x[3];
    _x[2] *= v;
    _x[3] *= v;

    // Covariance: P = F·P·Fᵀ + Q (constant-velocity F).
    final dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt2 * dt2;
    final p00 = _cov[0], p01 = _cov[1], p02 = _cov[2], p03 = _cov[3];
    final p10 = _cov[4], p11 = _cov[5], p12 = _cov[6], p13 = _cov[7];
    final p20 = _cov[8], p21 = _cov[9], p22 = _cov[10], p23 = _cov[11];
    final p30 = _cov[12], p31 = _cov[13], p32 = _cov[14], p33 = _cov[15];
    // F·P·Fᵀ (F = [[1,0,dt,0],[0,1,0,dt],[0,0,v,0],[0,0,0,v]]).
    final c00 = p00 + dt * (p20 + p02) + dt2 * p22;
    final c01 = p01 + dt * (p21 + p03) + dt2 * p23;
    final c02 = v * (p02 + dt * p22);
    final c03 = v * (p03 + dt * p23);
    final c10 = p10 + dt * (p30 + p12) + dt2 * p32;
    final c11 = p11 + dt * (p31 + p13) + dt2 * p33;
    final c12 = v * (p12 + dt * p32);
    final c13 = v * (p13 + dt * p33);
    final c20 = v * (p20 + dt * p22);
    final c21 = v * (p21 + dt * p23);
    final c22 = v * v * p22;
    final c23 = v * v * p23;
    final c30 = v * (p30 + dt * p32);
    final c31 = v * (p31 + dt * p33);
    final c32 = v * v * p32;
    final c33 = v * v * p33;
    // Q (constant-velocity, white acceleration noise q).
    final q = _q;
    final q00 = q * dt4 / 4, q02 = q * dt3 / 2;
    final q11 = q * dt4 / 4, q13 = q * dt3 / 2;
    final q20 = q * dt3 / 2, q22 = q * dt2;
    final q31 = q * dt3 / 2, q33 = q * dt2;
    _cov[0] = c00 + q00;
    _cov[1] = c01;
    _cov[2] = c02 + q02;
    _cov[3] = c03;
    _cov[4] = c10;
    _cov[5] = c11 + q11;
    _cov[6] = c12;
    _cov[7] = c13 + q13;
    _cov[8] = c20 + q20;
    _cov[9] = c21;
    _cov[10] = c22 + q22;
    _cov[11] = c23;
    _cov[12] = c30;
    _cov[13] = c31 + q31;
    _cov[14] = c32;
    _cov[15] = c33 + q33;
  }

  /// Measurement correction: z = [east, north], R = position variance.
  void _correct(List<double> z, double r) {
    // Innovation y = z − H·x  (H = [[1,0,0,0],[0,1,0,0]]).
    final y0 = z[0] - _x[0];
    final y1 = z[1] - _x[1];
    // S = H·P·Hᵀ + R = [[P00,P01],[P10,P11]] + R·I.
    final s00 = _cov[0] + r;
    final s01 = _cov[1];
    final s10 = _cov[4];
    final s11 = _cov[5] + r;
    final det = s00 * s11 - s01 * s10;
    if (det.abs() < 1e-12) return;
    final i00 = s11 / det, i01 = -s01 / det, i10 = -s10 / det, i11 = s00 / det;
    // K = (P·Hᵀ)·S⁻¹  (P·Hᵀ = column 0,1 of P).
    final k00 = _cov[0] * i00 + _cov[1] * i10;
    final k01 = _cov[0] * i01 + _cov[1] * i11;
    final k10 = _cov[4] * i00 + _cov[5] * i10;
    final k11 = _cov[4] * i01 + _cov[5] * i11;
    final k20 = _cov[8] * i00 + _cov[9] * i10;
    final k21 = _cov[8] * i01 + _cov[9] * i11;
    final k30 = _cov[12] * i00 + _cov[13] * i10;
    final k31 = _cov[12] * i01 + _cov[13] * i11;
    // x += K·y
    _x[0] += k00 * y0 + k01 * y1;
    _x[1] += k10 * y0 + k11 * y1;
    _x[2] += k20 * y0 + k21 * y1;
    _x[3] += k30 * y0 + k31 * y1;
    // P = (I − K·H)·P
    final p00 = _cov[0], p01 = _cov[1], p02 = _cov[2], p03 = _cov[3];
    final p10 = _cov[4], p11 = _cov[5], p12 = _cov[6], p13 = _cov[7];
    final p20 = _cov[8], p21 = _cov[9], p22 = _cov[10], p23 = _cov[11];
    final p30 = _cov[12], p31 = _cov[13], p32 = _cov[14], p33 = _cov[15];
    _cov[0] = p00 - k00 * p00 - k01 * p10;
    _cov[1] = p01 - k00 * p01 - k01 * p11;
    _cov[2] = p02 - k00 * p02 - k01 * p12;
    _cov[3] = p03 - k00 * p03 - k01 * p13;
    _cov[4] = p10 - k10 * p00 - k11 * p10;
    _cov[5] = p11 - k10 * p01 - k11 * p11;
    _cov[6] = p12 - k10 * p02 - k11 * p12;
    _cov[7] = p13 - k10 * p03 - k11 * p13;
    _cov[8] = p20 - k20 * p00 - k21 * p10;
    _cov[9] = p21 - k20 * p01 - k21 * p11;
    _cov[10] = p22 - k20 * p02 - k21 * p12;
    _cov[11] = p23 - k20 * p03 - k21 * p13;
    _cov[12] = p30 - k30 * p00 - k31 * p10;
    _cov[13] = p31 - k30 * p01 - k31 * p11;
    _cov[14] = p32 - k30 * p02 - k31 * p12;
    _cov[15] = p33 - k30 * p03 - k31 * p13;
  }

  /// Scalar measurement of SPEED (m/s) with variance [r] = σ² (the speed
  /// noise). The measurement is nonlinear in the state (√(vE²+vN²)), so it is
  /// linearized along the current velocity direction: H = [0,0,hx,hy] with
  /// h = unit velocity. This is how real GPS filters fuse the speed channel
  /// without a compass. Skipped when the filter believes it is (nearly)
  /// stopped — there is no reliable heading to project the speed onto yet.
  void _correctSpeed(double speed, double r) {
    final vx = _x[2], vy = _x[3];
    final s = math.sqrt(vx * vx + vy * vy);
    if (s < 0.3) return; // no heading when (nearly) stopped
    final hx = vx / s, hy = vy / s;
    // S = H·P·Hᵀ + R  (H·P·Hᵀ = hx·(hx·P22+hy·P23) + hy·(hx·P32+hy·P33)).
    final hp0 = hx * _cov[8] + hy * _cov[12]; // hᵀ·P column 0
    final hp1 = hx * _cov[9] + hy * _cov[13]; // hᵀ·P column 1
    final hp2 = hx * _cov[10] + hy * _cov[14]; // hᵀ·P column 2
    final hp3 = hx * _cov[11] + hy * _cov[15]; // hᵀ·P column 3
    final S = (hx * hp2 + hy * hp3) + r;
    if (S.abs() < 1e-12) return;
    final inv = 1.0 / S;
    // K = P·Hᵀ / S.
    final k0 = (hx * _cov[2] + hy * _cov[3]) * inv;
    final k1 = (hx * _cov[6] + hy * _cov[7]) * inv;
    final k2 = (hx * _cov[10] + hy * _cov[11]) * inv;
    final k3 = (hx * _cov[14] + hy * _cov[15]) * inv;
    // x += K·(z − H·x).
    final y = speed - s;
    _x[0] += k0 * y;
    _x[1] += k1 * y;
    _x[2] += k2 * y;
    _x[3] += k3 * y;
    // P = (I − K·H)·P  (H·P row = [hp0,hp1,hp2,hp3]).
    final p00 = _cov[0], p01 = _cov[1], p02 = _cov[2], p03 = _cov[3];
    final p10 = _cov[4], p11 = _cov[5], p12 = _cov[6], p13 = _cov[7];
    final p20 = _cov[8], p21 = _cov[9], p22 = _cov[10], p23 = _cov[11];
    final p30 = _cov[12], p31 = _cov[13], p32 = _cov[14], p33 = _cov[15];
    _cov[0] = p00 - k0 * hp0;
    _cov[1] = p01 - k0 * hp1;
    _cov[2] = p02 - k0 * hp2;
    _cov[3] = p03 - k0 * hp3;
    _cov[4] = p10 - k1 * hp0;
    _cov[5] = p11 - k1 * hp1;
    _cov[6] = p12 - k1 * hp2;
    _cov[7] = p13 - k1 * hp3;
    _cov[8] = p20 - k2 * hp0;
    _cov[9] = p21 - k2 * hp1;
    _cov[10] = p22 - k2 * hp2;
    _cov[11] = p23 - k2 * hp3;
    _cov[12] = p30 - k3 * hp0;
    _cov[13] = p31 - k3 * hp1;
    _cov[14] = p32 - k3 * hp2;
    _cov[15] = p33 - k3 * hp3;
  }

  /// Convert a lat/lng fix to local east/north metres (around the origin).
  List<double> _toEnu(LatLng p) {
    final north = (p.latitude - _refLat) * 111320.0;
    final east =
        (p.longitude - _refLng) * 111320.0 * math.cos(_refLat * math.pi / 180);
    return [east, north];
  }

  LatLng _fromEnu(double east, double north) {
    final dLat = north / 111320.0;
    final dLng = east / (111320.0 * math.cos(_refLat * math.pi / 180));
    return LatLng(_refLat + dLat, _refLng + dLng);
  }
}
