/// The simulated receiver: are the points ON the route, and is the error shaped
/// like a real phone's?
///
/// A simulation is only worth running if its input is honest. Two failure modes
/// make it useless, and both are caught here:
///   * points that drift off the planned route → the app decides the driver is
///     off-route, reroutes, and every road lookup then describes the detour;
///   * points that are perfect → the outlier gate, the heading filter and the
///     45° road-match test are never exercised, so the run proves nothing.
///
///   flutter test test/unit/gps_track_sim_test.dart
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/gps_track_sim.dart';

/// A straight 3 km north-south line — the simplest route a router could return.
List<LatLng> _line(int n, {double km = 3.0}) {
  const d = Distance();
  final out = <LatLng>[const LatLng(10.8000, 106.6400)];
  for (var i = 1; i < n; i++) {
    final p = d.offset(out.last, km * 1000 / n, 0);
    out.add(p);
  }
  return out;
}

/// Perpendicular distance from [p] to the polyline, metres.
double _offRouteM(List<LatLng> g, LatLng p) {
  const d = Distance();
  var best = double.infinity;
  for (var i = 1; i < g.length; i++) {
    final a = g[i - 1];
    final b = g[i];
    final seg = d.as(LengthUnit.Meter, a, b);
    if (seg <= 0) continue;
    // Project p onto the segment in local metres.
    final dx = (b.longitude - a.longitude) * 109000.0;
    final dy = (b.latitude - a.latitude) * 111000.0;
    final px = (p.longitude - a.longitude) * 109000.0;
    final py = (p.latitude - a.latitude) * 111000.0;
    final ll = dx * dx + dy * dy;
    final t = ll <= 0 ? 0.0 : ((px * dx + py * dy) / ll).clamp(0.0, 1.0);
    final off = math.sqrt(
      math.pow(px - t * dx, 2) + math.pow(py - t * dy, 2),
    );
    if (off < best) best = off;
  }
  return best;
}

void main() {
  const g = GpsSimOptions(paceMps: 14, dtSeconds: 1);

  test('a PERFECT receiver walks the route and stays on it', () {
    final route = _line(60);
    final track = synthesiseTrack(
      route,
      const GpsSimOptions(paceMps: 14, dtSeconds: 1, noise: 0),
      start: DateTime.utc(2026, 10, 9, 1),
    );
    expect(track.length, greaterThan(100), reason: '3 km at 14 m/s ≈ 214 s');
    var worst = 0.0;
    for (final f in track) {
      final off = _offRouteM(route, LatLng(f.lat, f.lng));
      worst = math.max(worst, off);
    }
    expect(worst, lessThan(0.5),
        reason: 'with no noise the fixes ARE the route, so a point off it means '
            'the walk drifted');
    // 1 Hz, monotonic, and the whole route covered.
    for (var i = 1; i < track.length; i++) {
      final dt = track[i].at.difference(track[i - 1].at).inMilliseconds;
      expect(dt, greaterThan(0));
    }
    expect(track.first.at.isBefore(track.last.at), isTrue);
  });

  test('a REAL receiver stays within its reported accuracy, not miles off', () {
    final route = _line(60);
    final track = synthesiseTrack(route, g, start: DateTime.utc(2026, 10, 9, 1));
    expect(track.length, greaterThan(100));
    var offWithSmallAcc = 0;
    for (final f in track) {
      final off = _offRouteM(route, LatLng(f.lat, f.lng));
      // The route must never be abandoned: even a DEGRADED fix (accuracy ≤ 80 m)
      // has to stay in the same small neighbourhood, or the app reroutes. The
      // deliberate gross outliers are the one exception — count them and keep
      // them rare, because they are what the outlier gate exists to reject.
      if (f.accuracy <= 20) {
        expect(off, lessThan(60),
            reason: 'a 20 m fix 60+ m off the road is not a receiver error, it '
                'is a wrong route');
        if (off < 25) offWithSmallAcc++;
      }
    }
    expect(offWithSmallAcc / track.length, greaterThan(0.8),
        reason: 'the overwhelming majority of normal fixes must sit close to '
            'the road');
  });

  test('the error is shaped like a phone: cold start, dropouts, outliers', () {
    final route = _line(60);
    final track = synthesiseTrack(
      route,
      const GpsSimOptions(paceMps: 14, dtSeconds: 1, noise: 1, seed: 3),
      start: DateTime.utc(2026, 10, 9, 1),
    );
    // A cold start that CONVERGES: the first fix is the coarse network fix the
    // gate must accept (see OutlierGate._coldStartAccuracyM), and the error
    // decays over the next few fixes instead of teleporting to full precision —
    // a teleport is a position jump the gate correctly rejects, which then
    // poisons every later fix (measured 2026-10-08: 20 of 175 fixes accepted).
    expect(track.first.accuracy, greaterThan(30),
        reason: 'a cold start hands out a coarse network fix');
    expect(track[5].accuracy, lessThan(track.first.accuracy),
        reason: 'the lock converges');
    expect(track[20].accuracy, lessThan(30),
        reason: 'and it converges to a satellite-quality fix');
    // Real gaps exist (dropouts), but the stream is still usable.
    final gaps = <double>[];
    for (var i = 1; i < track.length; i++) {
      gaps.add(track[i].at.difference(track[i - 1].at).inMilliseconds / 1000.0);
    }
    expect(gaps.where((g) => g > 1.5).length, greaterThan(0),
        reason: 'lost fixes must leave real gaps — the announcement cadences '
            'are measured in fix time and must survive them');
    expect(gaps.where((g) => g > 12).length, lessThan(gaps.length ~/ 10),
        reason: 'gaps must stay rare, or the drive is not a drive');
    // Accuracy varies rather than sitting at one value.
    final accs = track.map((f) => f.accuracy).toSet();
    expect(accs.length, greaterThan(10));
    // Heading jitters (a constant heading is a dead giveaway of synthetic input).
    final heads = track.map((f) => f.headingDeg.round()).toSet();
    expect(heads.length, greaterThan(1));
  });

  test('the same seed gives the same drive, a different seed does not', () {
    final route = _line(40);
    List<num> first(GpsSimOptions o) {
      final t = synthesiseTrack(route, o, start: DateTime.utc(2026, 10, 9, 1));
      return <num>[t.length, t.first.lat, t[5].lng, t.last.accuracy];
    }

    const seed7 = GpsSimOptions(paceMps: 14, noise: 1, seed: 7);
    const seed8 = GpsSimOptions(paceMps: 14, noise: 1, seed: 8);
    expect(first(seed7), first(seed7),
        reason: 'a run must be reproducible to be debuggable');
    expect(first(seed7), isNot(first(seed8)),
        reason: 'the seed must actually drive the noise');
  });

  test('noise 0 is not the same drive as noise 1 (the knob does something)', () {
    final route = _line(40);
    final clean = synthesiseTrack(
      route,
      const GpsSimOptions(paceMps: 14, noise: 0),
      start: DateTime.utc(2026, 10, 9, 1),
    );
    final noisy = synthesiseTrack(
      route,
      const GpsSimOptions(paceMps: 14, noise: 1, seed: 7),
      start: DateTime.utc(2026, 10, 9, 1),
    );
    expect(noisy.length, isNot(clean.length));
    expect(noisy.first.accuracy, greaterThan(clean.first.accuracy));
  });

  test('a degenerate route produces nothing instead of nonsense', () {
    expect(
      synthesiseTrack(const [], const GpsSimOptions()),
      isEmpty,
    );
    expect(
      synthesiseTrack(const [LatLng(10.8, 106.6)], const GpsSimOptions()),
      isEmpty,
    );
  });
}
