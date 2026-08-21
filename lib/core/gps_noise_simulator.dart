/// A seeded GPS noise simulator: produces realistic, reproducible synthetic
/// GPS fixes so the Kalman filter can be validated against known truth — and
/// so the on-device simulated drive can inject the same noise a real receiver
/// would (position jitter + a separate, noisy speed measurement).
///
/// Movement (constant-velocity or stationary), position noise and speed noise
/// are all configurable and reproducible via a seed.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// One simulated GPS sample: the true position, the noisy measurement, the
/// reported accuracy, and (optionally) a speed measurement with its own noise.
class SimulatedFix {
  const SimulatedFix({
    required this.truth,
    required this.measured,
    required this.accuracy,
    required this.trueSpeed,
    this.speedMps,
    this.speedNoise = 0,
  });

  /// Ground-truth position (where the vehicle really is).
  final LatLng truth;

  /// The noisy position a GPS receiver would report.
  final LatLng measured;

  /// Reported GPS accuracy in metres (≈ the position-noise σ).
  final double accuracy;

  /// Ground-truth speed in m/s.
  final double trueSpeed;

  /// Noisy speed measurement in m/s (`null` = receiver does not report speed).
  final double? speedMps;

  /// σ of the speed measurement in m/s (the "speed noise").
  final double speedNoise;
}

/// Simulates a vehicle driving (or parked) with a GPS receiver at a fixed
/// cadence. The truth advances along [headingDeg] at [speedMps]; each emitted
/// fix is the truth plus Gaussian position noise (σ = [positionSigma]) and,
/// when [reportSpeed], a Gaussian-corrupted speed (σ = [speedSigma]).
///
/// Set [speedMps] = 0 (or to a low value) to simulate a parked car: the truth
/// stops moving but the reported fixes still jitter — the classic drift test.
class GpsNoiseSimulator {
  GpsNoiseSimulator({
    LatLng? origin,
    this.headingDeg = 90, // degrees, 0 = north, clockwise (east = 90)
    this.speedMps = 10.0,
    this.positionSigma = 5.0, // m — position measurement noise σ
    this.speedSigma = 1.0, // m/s — speed measurement noise σ
    this.fixIntervalMs = 1000,
    this.reportSpeed = true,
    int? seed,
  }) : _origin = origin ?? const LatLng(10.8, 106.65),
       _rng = math.Random(seed ?? 42) {
    _truth = _origin;
  }

  static const double mPerDegLat = 111320.0;
  static double mPerDegLng(double lat) =>
      mPerDegLat * math.cos(lat * math.pi / 180);

  /// Distance in metres between two lat/lng points (local flat-Earth, good
  /// enough for the small areas the simulator works in).
  static double metersBetween(LatLng a, LatLng b) {
    final dLat = (a.latitude - b.latitude) * mPerDegLat;
    final dLng = (a.longitude - b.longitude) * mPerDegLng(a.latitude);
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  final LatLng _origin;
  final double headingDeg;
  final double positionSigma;
  final double speedSigma;
  final int fixIntervalMs;
  final bool reportSpeed;
  final math.Random _rng;

  /// Current ground-truth position (starts at [origin]).
  LatLng get truth => _truth;
  LatLng _truth = const LatLng(0, 0);

  /// Current ground-truth speed, m/s. Change it between [next] calls to
  /// accelerate, brake or stop the vehicle.
  double speedMps;

  /// Advance the vehicle one fix interval and emit the noisy measurement.
  SimulatedFix next() {
    final dt = fixIntervalMs / 1000.0;
    // Advance the truth along the heading.
    final rad = headingDeg * math.pi / 180;
    final dE = math.sin(rad) * speedMps * dt; // metres east
    final dN = math.cos(rad) * speedMps * dt; // metres north
    _truth = LatLng(
      _truth.latitude + dN / mPerDegLat,
      _truth.longitude + dE / mPerDegLng(_truth.latitude),
    );
    // Corrupt the measurement with position noise.
    final nE = _gauss() * positionSigma;
    final nN = _gauss() * positionSigma;
    final measured = LatLng(
      _truth.latitude + nN / mPerDegLat,
      _truth.longitude + nE / mPerDegLng(_truth.latitude),
    );
    return SimulatedFix(
      truth: _truth,
      measured: measured,
      accuracy: positionSigma,
      trueSpeed: speedMps,
      speedMps: reportSpeed ? speedMps + _gauss() * speedSigma : null,
      speedNoise: speedSigma,
    );
  }

  /// Standard normal via Box–Muller (seeded, so traces are reproducible).
  double _gauss() {
    var u = 0.0, v = 0.0, s = 0.0;
    do {
      u = 2 * _rng.nextDouble() - 1;
      v = 2 * _rng.nextDouble() - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);
    return u * math.sqrt(-2 * math.log(s) / s);
  }
}
