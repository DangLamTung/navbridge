/// Synthesise the GPS points a drive along a PLANNED route would produce.
///
/// Why this exists: a simulation must feed the algorithm real-looking GPS, and
/// hand-made tracks are useless for it in two ways —
///   * points that are NOT on the planned route make the app think the driver is
///     off-route and REROUTE, so every road lookup then describes the detour
///     instead of the road being driven (the mistake behind "the replay is not
///     comparable to the recording", tool/sim_vs_real.py);
///   * clean, exact points never exercise the parts that matter — the outlier
///     gate, the heading filter, the road matcher's 45° test, the "is the GPS
///     fix good enough to say anything" logic.
///
/// So the points are WALKED along the router's own geometry (they are on the
/// route by construction) and then perturbed with the error structure a phone
/// actually has: lateral scatter proportional to the reported accuracy, jitter
/// in speed and heading, slow and degraded fixes, dropouts in a tree alley, an
/// occasional gross outlier, and a coarse network fix on the cold start.
///
/// Deterministic for a given [GpsSimOptions.seed], so a run can be repeated and
/// a fix in the algorithm can be re-tested against the same input.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/trip_replay.dart' show ReplayFix;

/// How the synthetic drive should behave. All the noise knobs are here so the
/// driver (`tool/sim_track.py`) can vary them per run instead of rebuilding.
class GpsSimOptions {
  const GpsSimOptions({
    this.paceMps = 13.9, // 50 km/h
    this.dtSeconds = 1.0,
    this.noise = 1.0,
    this.seed = 7,
    this.accuracyBaseM = 5.0,
    this.coldStartFixes = 2,
    this.coldStartAccuracyM = 420.0,
    this.dropoutChance = 0.02,
    this.degradedChance = 0.03,
    this.outlierChance = 0.004,
  });

  /// Target ground speed (m/s). 13.9 = 50 km/h, 15.0 = 54 km/h.
  final double paceMps;

  /// Fix interval. 1 s is what the phone's receiver streams.
  final double dtSeconds;

  /// Multiplier on EVERY error term: 0 = a perfect trace (useful to isolate the
  /// algorithm from the receiver), 1 = a normal phone, 2 = a bad day.
  final double noise;

  final int seed;

  /// Median reported accuracy, metres. Real devices sit at 4-10 m.
  final double accuracyBaseM;

  /// The FIRST fix's accuracy during the cold start, metres; it decays to
  /// [accuracyBaseM] over [coldStartFixes] fixes.
  final double coldStartAccuracyM;

  /// How many fixes the cold start lasts: a coarse network/cell fix before the
  /// satellite lock, converging to full precision over this many fixes
  /// ([GpsSimOptions.coldStartAccuracyM] is the first one's error).
  ///
  /// ⭐ It CONVERGES rather than switching, because that is what a receiver
  /// does and because the alternative is not a valid input: jumping from a
  /// 300 m fix straight to a 5 m one is a 300 m position jump in one second,
  /// which the outlier gate correctly rejects — and once rejected, every later
  /// fix is still measured against the old reference. Measured 2026-10-08:
  /// a teleporting cold start got 20 of 175 fixes accepted and caused 3
  /// spurious reroutes; a converging one is accepted throughout.
  final int coldStartFixes;

  /// Chance a fix is simply LOST (a tree alley, a tunnel, a phone in a pocket).
  /// Creates the multi-second gaps the cadences must survive.
  final double dropoutChance;

  /// Chance of a degraded fix: accuracy 25-80 m, lateral error in proportion.
  final double degradedChance;

  /// Chance of a gross outlier: a fix 120-400 m off the road, which the outlier
  /// gate is supposed to reject (and, if it does not, the road matcher to
  /// survive).
  final double outlierChance;

  GpsSimOptions copyWith({
    double? paceMps,
    double? dtSeconds,
    double? noise,
    int? seed,
    double? accuracyBaseM,
  }) => GpsSimOptions(
    paceMps: paceMps ?? this.paceMps,
    dtSeconds: dtSeconds ?? this.dtSeconds,
    noise: noise ?? this.noise,
    seed: seed ?? this.seed,
    accuracyBaseM: accuracyBaseM ?? this.accuracyBaseM,
    coldStartFixes: coldStartFixes,
    coldStartAccuracyM: coldStartAccuracyM,
    dropoutChance: dropoutChance,
    degradedChance: degradedChance,
    outlierChance: outlierChance,
  );
}

/// Box-Muller: Dart's `Random` has no gaussian, and a uniform error would be
/// the wrong shape — GPS error is a bell, which is why a single bad fix is rare
/// and a 20 m fix is not.
double _gauss(math.Random r) {
  var u = r.nextDouble();
  if (u <= 0) u = 1e-9;
  final v = r.nextDouble();
  return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
}

/// Cumulative metres along [geometry].
List<double> cumulativeMeters(List<LatLng> geometry) {
  const d = Distance();
  final cum = List<double>.filled(geometry.length, 0);
  for (var i = 1; i < geometry.length; i++) {
    cum[i] = cum[i - 1] + d.as(LengthUnit.Meter, geometry[i - 1], geometry[i]);
  }
  return cum;
}

/// The point [metres] along [geometry], with the local bearing there.
({LatLng point, double bearingDeg}) _alongTrack(
  List<LatLng> geometry,
  List<double> cum,
  double metres,
) {
  const d = Distance();
  final total = cum.last;
  final m = metres.clamp(0.0, total);
  var lo = 0;
  var hi = cum.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (cum[mid] < m) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final i = lo == 0 ? 0 : lo - 1;
  final j = math.min(i + 1, geometry.length - 1);
  final seg = cum[j] - cum[i];
  final t = seg <= 0 ? 0.0 : ((m - cum[i]) / seg).clamp(0.0, 1.0);
  final a = geometry[i];
  final b = geometry[j];
  final p = LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );
  return (
    point: p,
    bearingDeg: seg <= 0 ? 0.0 : (d.bearing(a, b) + 360) % 360,
  );
}

/// Offset [p] [metresM] metres perpendicular to [bearingDeg] (`+` = right of
/// travel), the way a receiver's error moves the dot off the road.
LatLng _offset(LatLng p, double bearingDeg, double metresM) {
  const earth = 6371000.0;
  final rad = (bearingDeg + 90) * math.pi / 180.0;
  final dLat = (metresM * math.cos(rad)) / earth * 180.0 / math.pi;
  final dLng = (metresM * math.sin(rad)) /
      (earth * math.cos(p.latitude * math.pi / 180.0)) *
      180.0 /
      math.pi;
  return LatLng(p.latitude + dLat, p.longitude + dLng);
}

/// Walk [geometry] at [GpsSimOptions.paceMps] and return the fixes a phone
/// would have logged for that drive.
///
/// [start] is the first fix's timestamp (defaults to now, UTC). Gaps come from
/// the walk, so a dropout shows up as a real multi-second gap — which is what
/// the announcement cadences are measured against (`nav_clock.dart`).
List<ReplayFix> synthesiseTrack(
  List<LatLng> geometry,
  GpsSimOptions o, {
  DateTime? start,
}) {
  if (geometry.length < 2) return const [];
  final cum = cumulativeMeters(geometry);
  final total = cum.last;
  if (total < 1) return const [];

  final r = math.Random(o.seed);
  final t0 = (start ?? DateTime.now().toUtc());
  final n = o.noise.clamp(0.0, 5.0);

  final out = <ReplayFix>[];
  var travelled = 0.0;
  var i = 0;
  while (travelled < total) {
    final at = t0.add(
      Duration(milliseconds: (i * o.dtSeconds * 1000).round()),
    );
    i++;
    // ── the pace: the driver's own variation around the target speed
    final pace = (o.paceMps * (1 + 0.12 * n * _gauss(r))).clamp(0.5, 60.0);
    travelled += pace * o.dtSeconds;

    final onTrack = _alongTrack(geometry, cum, travelled);
    var p = onTrack.point;
    var heading = (onTrack.bearingDeg + 6 * n * _gauss(r)) % 360;

    // ── accuracy, and with it the SIZE of the lateral error: a receiver's dot
    // moves off the road roughly in proportion to what it reports.
    var accuracy = (o.accuracyBaseM * (1 + 0.6 * n * _gauss(r).abs()))
        .clamp(1.0, 500.0);
    var lateral = accuracy * 0.5 * n * _gauss(r);

    if (i <= o.coldStartFixes && n > 0) {
      // The coarse network fix handed out before the satellite lock, decaying to
      // a satellite-quality fix — the sequence `OutlierGate._coldStartAccuracyM`
      // (500 m) exists to accept.
      final t = i / (o.coldStartFixes + 1); // 0 → ~1 across the warm-up
      final decay = (1 - t) * (1 - t);
      accuracy = 8 + (o.coldStartAccuracyM - 8) * decay;
      // ⭐ The REPORTED accuracy is the gate's business; the POSITION is the
      // route matcher's. A receiver handing out a 420 m fix is usually still
      // roughly where it is — it just does not know how well — so the dot must
      // not drift hundreds of metres off the road. Measured 2026-10-08 with the
      // error following the accuracy (×0.35): the car was ~200 m off the route
      // on the first fixes and the app rerouted 3 times in the first 6 s of
      // every run, replacing the route the run was meant to follow.
      lateral = math.min(accuracy * 0.35, 25.0) * _gauss(r);
    } else if (n > 0 && r.nextDouble() < o.degradedChance) {
      // A degraded fix: still positionally sane, explicitly untrustworthy.
      accuracy = 25 + r.nextDouble() * 55;
      lateral = accuracy * 0.5 * _gauss(r);
    } else if (n > 0 && r.nextDouble() < o.outlierChance) {
      // A gross outlier: the receiver was simply wrong. Street-scale, not
      // city-scale — a 300 m error is a different road, and the gate then spends
      // fixes rejecting perfectly good readings against a poisoned reference.
      lateral = (60 + r.nextDouble() * 140) * (r.nextBool() ? 1 : -1);
      accuracy = 30 + r.nextDouble() * 40;
      heading = (heading + 90 * (r.nextBool() ? 1 : -1)) % 360;
    }
    p = _offset(p, heading, lateral);

    out.add(
      ReplayFix(
        at: at,
        lat: p.latitude,
        lng: p.longitude,
        accuracy: accuracy,
        speedMps: pace,
        headingDeg: heading,
      ),
    );

    // ── a lost fix: skip the next interval, leaving a real gap in the stream.
    if (n > 0 && r.nextDouble() < o.dropoutChance) {
      travelled += pace * o.dtSeconds * (1 + r.nextDouble() * 3);
      i++;
    }
  }
  return out;
}
