/// Validates that `LocationKalman` actually works against a REALISTIC noisy
/// GPS trace produced by `GpsNoiseSimulator` — movement, position noise AND a
/// separate speed measurement with its own noise. This is the "does the
/// Kalman smooth real-world noise?" harness.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/gps_noise_simulator.dart';
import 'package:navbridge/core/location_kalman.dart';

void main() {
  test('simulator emits noisy fixes around a moving truth', () {
    final sim = GpsNoiseSimulator(
      speedMps: 10,
      positionSigma: 5,
      speedSigma: 1.5,
      seed: 42,
    );
    final first = sim.next();
    expect(
      GpsNoiseSimulator.metersBetween(first.truth, first.measured),
      lessThan(15),
    ); // noise, not huge
    // Over 10 s at 10 m/s the truth advances ~100 m along east.
    var last = first;
    for (var i = 0; i < 10; i++) {
      last = sim.next();
    }
    final travelled = GpsNoiseSimulator.metersBetween(first.truth, last.truth);
    expect(travelled, greaterThan(90));
    expect(travelled, lessThan(110));
    // The speed measurement is noisy around the true 10 m/s.
    expect((last.speedMps! - 10).abs(), lessThan(6));
    expect(last.accuracy, 5.0);
  });

  test('same seed reproduces the same trace', () {
    final a = GpsNoiseSimulator(seed: 7);
    final b = GpsNoiseSimulator(seed: 7);
    for (var i = 0; i < 5; i++) {
      final fa = a.next();
      final fb = b.next();
      expect(fa.measured.latitude, fb.measured.latitude);
      expect(fa.measured.longitude, fb.measured.longitude);
      expect(fa.speedMps, fb.speedMps);
    }
  });

  test('Kalman smooths a moving trace AND uses the speed channel', () {
    final sim = GpsNoiseSimulator(
      speedMps: 10,
      positionSigma: 5,
      speedSigma: 1.5,
      seed: 42,
    );
    final kf = LocationKalman();
    const base = 1_700_000_000_000;
    double rawErr = 0, filtErr = 0;
    LatLng? lastFilt;
    final speedErrs = <double>[];
    for (var i = 0; i < 25; i++) {
      final sf = sim.next();
      kf.update(
        sf.measured,
        accuracy: sf.accuracy,
        speedMps: sf.speedMps,
        speedNoise: sf.speedNoise,
        nowMs: base + i * sim.fixIntervalMs,
      );
      final f = kf.position!;
      lastFilt = f;
      rawErr += GpsNoiseSimulator.metersBetween(sf.measured, sf.truth);
      filtErr += GpsNoiseSimulator.metersBetween(f, sf.truth);
      if (i >= 5) speedErrs.add((kf.speedMps - sf.trueSpeed).abs());
    }
    // (a) Smoothing: the filtered path is closer to the truth than the raw
    // noisy GPS — the whole point of the filter.
    expect(filtErr, lessThan(rawErr));
    expect(
      filtErr,
      lessThan(rawErr * 0.85),
      reason: 'filtErr=$filtErr rawErr=$rawErr',
    );
    // (b) Tracking: no lag — ends near the true position.
    final trueEnd = sim.truth;
    expect(GpsNoiseSimulator.metersBetween(lastFilt!, trueEnd), lessThan(6.0));
    // (c) Speed: the fused speed measurement keeps the velocity estimate
    // close to the true speed after warmup (within ~2σ of the speed noise).
    final meanSpeedErr = speedErrs.reduce((a, b) => a + b) / speedErrs.length;
    expect(
      meanSpeedErr,
      lessThan(2.5),
      reason: 'mean speed error=$meanSpeedErr m/s',
    );
  });

  test('Kalman speed estimate is sharper WITH the speed channel', () {
    // Same noisy positions; one filter gets the speed measurement, one does
    // not. The one with the speed channel should track the true speed more
    // tightly (fewer wild swings from position noise alone).
    double speedErrWith = 0, speedErrWithout = 0;
    final kfWith = LocationKalman();
    final kfWithout = LocationKalman();
    const base = 1_700_000_000_000;
    final simA = GpsNoiseSimulator(
      speedMps: 12,
      positionSigma: 6,
      speedSigma: 1.5,
      seed: 11,
    );
    final simB = GpsNoiseSimulator(
      speedMps: 12,
      positionSigma: 6,
      speedSigma: 1.5,
      seed: 11,
    );
    for (var i = 0; i < 30; i++) {
      final fa = simA.next();
      final fb = simB.next();
      kfWith.update(
        fa.measured,
        accuracy: fa.accuracy,
        speedMps: fa.speedMps,
        speedNoise: fa.speedNoise,
        nowMs: base + i * 1000,
      );
      kfWithout.update(
        fb.measured,
        accuracy: fb.accuracy,
        nowMs: base + i * 1000,
      );
      if (i >= 8) {
        speedErrWith += (kfWith.speedMps - fa.trueSpeed).abs();
        speedErrWithout += (kfWithout.speedMps - fa.trueSpeed).abs();
      }
    }
    expect(speedErrWith, lessThan(speedErrWithout));
  });

  test('Kalman does not drift while the simulated car is parked', () {
    final sim = GpsNoiseSimulator(
      speedMps: 0,
      positionSigma: 3,
      speedSigma: 1.0,
      seed: 7,
    );
    final kf = LocationKalman();
    const base = 1_700_000_000_000;
    final start = sim.truth;
    for (var i = 0; i < 40; i++) {
      final sf = sim.next();
      kf.update(
        sf.measured,
        accuracy: sf.accuracy,
        speedMps: sf.speedMps,
        speedNoise: sf.speedNoise,
        nowMs: base + i * 1000,
      );
      if (i >= 15) {
        // After warmup the estimate must hug the start in a bounded band —
        // GPS jitter around the parked spot is fine, but it must NEVER
        // integrate into a growing drift (the classic failure would reach
        // tens of metres).
        expect(
          GpsNoiseSimulator.metersBetween(kf.position!, start),
          lessThan(6.0),
          reason: 'parked drift at fix $i',
        );
      }
    }
    expect(kf.speedMps, lessThan(2.0));
  });
}
