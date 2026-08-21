/// Tests for the 4-state constant-velocity GPS Kalman filter
/// (`location_kalman.dart`). Uses deterministic wall-clock injection (nowMs)
/// so the predict/correct cadence is reproducible.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/location_kalman.dart';

// Metres per degree at the test latitude (~10.8°N, Saigon).
final double _mPerDegLat = 111320.0;
final double _mPerDegLng = 111320.0 * math.cos(10.8 * math.pi / 180);

double _degLat(double m) => m / _mPerDegLat;
double _degLng(double m) => m / _mPerDegLng;

double _dist(LatLng a, LatLng b) {
  final dLat = (a.latitude - b.latitude) * _mPerDegLat;
  final dLng = (a.longitude - b.longitude) * _mPerDegLng;
  return math.sqrt(dLat * dLat + dLng * dLng);
}

void main() {
  final origin = LatLng(10.8, 106.65);

  test('smooths a jittery trace and tracks a moving car', () {
    final kf = LocationKalman();
    final rng = math.Random(42);
    const base = 1_700_000_000_000;
    // Car drives EAST at 10 m/s, GPS fixes every 1 s with ~±5 m noise.
    double rawErr = 0, filtErr = 0;
    LatLng? lastFilt;
    for (var i = 0; i < 25; i++) {
      final t = i * 1000;
      final truePos = LatLng(
        origin.latitude,
        origin.longitude + _degLng(10.0 * i),
      );
      final noisy = LatLng(
        truePos.latitude + _degLat((rng.nextDouble() - 0.5) * 10),
        truePos.longitude + _degLng((rng.nextDouble() - 0.5) * 10),
      );
      kf.update(noisy, nowMs: base + t);
      final f = kf.position!;
      lastFilt = f;
      rawErr += _dist(noisy, truePos);
      filtErr += _dist(f, truePos);
    }
    // The filtered path should be closer to the true path than the raw GPS
    // (jitter smoothed away) — a real-world 1 Hz position-only filter
    // typically cuts ~15-25% of the error while tracking motion.
    expect(filtErr, lessThan(rawErr));
    expect(filtErr, lessThan(rawErr * 0.9));
    // And it tracks the motion: final estimate is near the true end (within a
    // few metres), not lagging behind by tens of metres.
    final trueEnd = LatLng(origin.latitude, origin.longitude + _degLng(240.0));
    expect(_dist(lastFilt!, trueEnd), lessThan(5.0));
  });

  test('does not drift while stationary (velocity damping)', () {
    final kf = LocationKalman();
    final rng = math.Random(7);
    const base = 1_700_000_000_000;
    // Car parked: every fix is the same spot with ~±2 m GPS jitter.
    for (var i = 0; i < 40; i++) {
      final noisy = LatLng(
        origin.latitude + _degLat((rng.nextDouble() - 0.5) * 4),
        origin.longitude + _degLng((rng.nextDouble() - 0.5) * 4),
      );
      kf.update(noisy, nowMs: base + i * 1000);
      final f = kf.position!;
      // After the first couple of fixes the estimate must hug the start — the
      // velocity-damped Kalman must NOT integrate jitter into a drift.
      if (i >= 3) {
        expect(
          _dist(f, origin),
          lessThan(4.0),
          reason: 'stationary drift at fix $i: ${_dist(f, origin)} m',
        );
      }
    }
    expect(kf.speedMps, lessThan(2.0));
  });

  test('predict dead-reckons forward between fixes', () {
    final kf = LocationKalman();
    const base = 1_700_000_000_000;
    // Establish eastward motion with two clean fixes 1 s apart.
    final p0 = LatLng(origin.latitude, origin.longitude);
    final p1 = LatLng(origin.latitude, origin.longitude + _degLng(10.0));
    kf.update(p0, nowMs: base);
    kf.update(p1, nowMs: base + 1000);
    final before = kf.position!;
    // 0.5 s later the prediction should be east of where we were.
    final predicted = kf.predict(0.5, nowMs: base + 1500);
    final dLat = predicted.latitude - before.latitude;
    final dLng = predicted.longitude - before.longitude;
    final moved = _dist(before, predicted);
    // ~5 m glide in 0.5 s at 10 m/s (Kalman speed may be slightly under).
    expect(moved, greaterThan(1.0));
    expect(moved, lessThan(12.0));
    expect(dLng, greaterThan(0)); // moved east, not west
    expect(dLat.abs(), lessThan(0.001));
  });

  test('snapTo pins the position without touching velocity', () {
    final kf = LocationKalman();
    const base = 1_700_000_000_000;
    // Establish eastward motion (~10 m/s) with two clean fixes 1 s apart.
    final p0 = LatLng(origin.latitude, origin.longitude);
    final p1 = LatLng(origin.latitude, origin.longitude + _degLng(10.0));
    kf.update(p0, nowMs: base);
    kf.update(p1, nowMs: base + 1000);
    expect(kf.speedMps, greaterThan(1.0));
    final before = kf.speedMps;
    // Pin to an off-line point (e.g. the projected route point).
    final target = LatLng(
      origin.latitude + _degLat(5),
      origin.longitude + _degLng(3),
    );
    kf.snapTo(target);
    // Position is now pinned to the target…
    expect(_dist(kf.position!, target), lessThan(0.5));
    // …but the velocity estimate is preserved (no lag introduced).
    expect(kf.speedMps, closeTo(before, 0.5));
    // A subsequent predict continues from the pinned spot along the heading.
    final p = kf.predict(0.5, nowMs: base + 1500);
    expect(p.longitude, greaterThan(target.longitude)); // still moving east
  });
}
