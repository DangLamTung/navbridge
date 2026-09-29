// REAL-DATA LONG-TRIP TEST — Hà Nội → Sài Gòn down QL1A, 1,686 km, 19,663 route
// points, 22 h at 77 km/h.
//
// Why this exists: every recorded drive in this repo is <= 8.8 km and inside
// HCMC, so the app's country-scale paths had no coverage at all — and that is
// where this app has broken before (2026-08-24: the app ANR'd while navigating
// a 2826 km route). The first run of this test found two long-route defects,
// both fixed and pinned below:
//
//   1. the maneuver-vertex lookup scanned the WHOLE geometry 2-3x per GPS fix,
//      so the per-fix cost grew with route length — 14.0x on a route 16x
//      longer. After the fix: 0.7x (see the sweep test);
//   2. the engine's cumulative length ran 0.07 % SHORT of the route's own
//      distance, which is ~1.2 km at the destination: the banner stopped at
//      "1.2 km to go" and never arrived.
//
// ⚠ The corridor matters: asked for Hà Nội → Sài Gòn with no waypoints, the
// OSRM demo profile answers with a SHORTER route that leaves the country
// (Cầu Treo → Thakhek → Pakse → Stung Treng → Kratie → Mộc Bài, 1,486 km).
// That fixture was useless — it missed Huế by 211 km and passed 0.2 km from
// Pakse. This one is pinned through Vinh, Huế, Đà Nẵng and Nha Trang, and
// `tool/fetch_long_route.py` now refuses a route that misses those towns or
// comes within 20 km of the foreign ones.
//
// Fixture: `test/data/hn_sg_route.json` — a real OSRM car route, geometry
// exactly as the router returned it. The DRIVE over it is synthesised at the
// router's own mean pace, because a drive this long cannot be recorded in one
// go; nothing here needs network.
//
//   flutter test test/func/trip     (part of tool/check.sh's FUNCTION line)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_scan.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/trip_replay.dart';

const _path = 'test/data/hn_sg_route.json';

Map<String, dynamic> _fixture() =>
    jsonDecode(File(_path).readAsStringSync()) as Map<String, dynamic>;

/// Fixes along [geom] at [paceMps], one per geometry vertex, times running from
/// a fixed instant so the test is deterministic.
List<ReplayFix> _drive(List<List<dynamic>> geom, double paceMps) {
  final t0 = DateTime.utc(2026, 9, 27, 1);
  final out = <ReplayFix>[];
  var cum = 0.0;
  for (var i = 0; i < geom.length; i++) {
    final lat = (geom[i][0] as num).toDouble();
    final lng = (geom[i][1] as num).toDouble();
    var heading = 0.0;
    if (i > 0) {
      final p = LatLng(
        (geom[i - 1][0] as num).toDouble(),
        (geom[i - 1][1] as num).toDouble(),
      );
      cum += const Distance().as(LengthUnit.Meter, p, LatLng(lat, lng));
      heading = const Distance().bearing(p, LatLng(lat, lng));
    }
    out.add(
      ReplayFix(
        at: t0.add(Duration(microseconds: (cum / paceMps * 1e6).round())),
        lat: lat,
        lng: lng,
        accuracy: 10,
        speedMps: paceMps,
        headingDeg: heading,
      ),
    );
  }
  return out;
}

/// Consecutive fixes walked through [route] — the per-fix cost of driving.
int _sweepMicros(OsrmRoute route, List<ReplayFix> fixes, double pace, int n) {
  final engine = TurnByTurnEngine(
    route,
    maxSpeedMps: RouteProfile.car.legalMaxMps,
  );
  final w = Stopwatch()..start();
  for (var k = 0; k < n; k++) {
    final f = fixes[k % fixes.length];
    engine.update(LatLng(f.lat, f.lng), speedMps: pace);
  }
  w.stop();
  return w.elapsedMicroseconds;
}

void main() {
  final fx = _fixture();
  final geom = (fx['geometry'] as List).cast<List<dynamic>>();
  final osrmM = (fx['osrm']['distanceM'] as num).toDouble();
  final osrmS = (fx['osrm']['durationS'] as num).toDouble();
  final pace = (fx['osrm']['meanPaceMps'] as num).toDouble();
  final fixes = _drive(geom, pace);
  final route = routeFromTrack(fixes);

  group('the 1,486 km route the app builds', () {
    test('is the router\'s own route: distance, duration, every point', () {
      expect(route.geometry.length, geom.length);
      expect(route.distance, closeTo(osrmM, osrmM * 0.005));
      expect(route.duration, closeTo(osrmS, osrmS * 0.005));
      expect(route.steps.length, greaterThan(100));
      // Endpoints are the drive's first and last fix (Hà Nội → Sài Gòn).
      expect(route.geometry.first.latitude, closeTo(21.0278, 1e-3));
      expect(route.geometry.last.latitude, closeTo(10.82309, 1e-3));
    });

    test('builds without blowing up (blow-up detector, not a perf target)', () {
      // Measured 15-47 ms for 16,650 points. An accidental O(n^2) build would
      // take minutes — that is what this guards.
      final w = Stopwatch()..start();
      routeFromTrack(fixes);
      w.stop();
      expect(w.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('navigation at country scale', () {

    test('6 cases', () {
    // ---- case: set off: the whole route is ahead, nothing behind ----
    (() {
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final f = fixes.first;
        final nav = engine.update(LatLng(f.lat, f.lng), speedMps: pace);
        expect(nav.remainingMeters, closeTo(route.distance, osrmM * 0.005));
        expect(nav.progress, lessThan(0.001));

    })();


    // ---- case: progress is a fraction of DISTANCE, not of point count ----
    (() {
        // Half the route's length is 50.7 % of its points on this drive, so a
        // position that lands "half way" between two different points is not
        // obviously the same thing — the numbers must follow the distance.
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final half = engine.positionAtDistance(route.distance / 2);
        final nav = engine.update(half, speedMps: pace);
        expect(nav.progress, closeTo(0.5, 0.01));
        expect(nav.remainingMeters, closeTo(route.distance / 2, osrmM * 0.01));

    })();


    // ---- case: progress, remaining and cumulative stay consistent all the way ----
    (() {
        // Fed at 20 points spread over the drive, independently of how the
        // geometry is sampled: progress is the fraction of the DISTANCE done,
        // remaining is what is left of it, and the two must agree with the
        // engine's own cumulative at every one of them.
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        for (var k = 0; k < 20; k++) {
          final along = route.distance * k / 19;
          final nav = engine.update(
            engine.positionAtDistance(along),
            speedMps: pace,
          );
          final cum = engine.currentCumulative;
          expect(nav.progress, closeTo(cum / route.distance, 0.002));
          expect(nav.remainingMeters, closeTo(route.distance - cum, 5));
        }

    })();


    // ---- case: arriving: the last fix is the destination, 0 m out ----
    (() {
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final f = fixes.last;
        final nav = engine.update(LatLng(f.lat, f.lng), speedMps: pace);
        expect(nav.remainingMeters, lessThan(50)); // was ~1,200 m before the fix
        expect(nav.progress, greaterThan(0.999));
        expect(nav.iconCode, iconArrive);

    })();


    // ---- case: a 144 km/h burst cannot shorten the ETA past the law ----
    (() {
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        for (var k = 0; k < 20; k++) {
          final f = fixes[k + 100];
          engine.update(LatLng(f.lat, f.lng), speedMps: 40);
        }
        // Factor = profile pace ÷ actual pace, clamped: the profile is ~22 m/s
        // and the legal ceiling caps a 40 m/s burst at the vehicle maximum.
        expect(engine.etaFactor, greaterThanOrEqualTo(0.6));
        expect(engine.etaFactor, lessThan(1.0));

    })();


    // ---- case: a crawl is capped at 3x the profile ETA ----
    (() {
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        for (var k = 0; k < 20; k++) {
          final f = fixes[k + 100];
          engine.update(LatLng(f.lat, f.lng), speedMps: 5);
        }
        expect(engine.etaFactor, closeTo(3.0, 0.001));

    })();
    });

  });

  group('arrival is only reached at the destination', () {
    // A straight track: no turn is detected, so the route comes out as
    // [depart, arrive]. The bug this guards: the depart step used the LAST
    // turn's cumulative (0 when there is no turn) and no step covered the leg
    // after the last turn, so `_stepCum` stopped short of the route total and
    // the banner read "0 m · đến nơi" from the very first fix of a 24 km
    // replay while the console still had 1 200 fixes to feed.
    final straight = <List<dynamic>>[
      for (var i = 0; i < 200; i++) [15.0 + i * 0.00045, 108.0], // ~50 m apart
    ];
    final straightFixes = _drive(straight, 15);
    final straightRoute = routeFromTrack(straightFixes);


    test('4 cases', () {
    // ---- case: a turn-free route still tiles its whole length ----
    (() {
        final sum = straightRoute.steps.fold<double>(0, (a, s) => a + s.distance);
        expect(straightRoute.steps.length, 2); // depart + arrive
        expect(sum, closeTo(straightRoute.distance, 0.5));

    })();


    // ---- case: the country-scale route tiles its whole length ----
    (() {
        final sum = route.steps.fold<double>(0, (a, s) => a + s.distance);
        expect(sum, closeTo(route.distance, 1));

    })();


    // ---- case: the first fix is not arrival, and shows the distance ahead ----
    (() {
        for (final r in [straightRoute, route]) {
          final engine = TurnByTurnEngine(
            r,
            maxSpeedMps: RouteProfile.car.legalMaxMps,
          );
          final f = r == straightRoute ? straightFixes.first : fixes.first;
          final nav = engine.update(LatLng(f.lat, f.lng), speedMps: 15);
          expect(nav.iconCode, isNot(iconArrive));
          expect(nav.remainingMeters, closeTo(r.distance, r.distance * 0.01));
          expect(nav.meter, greaterThan(0));
        }
        // On the turn-free route the next manoeuvre IS the arrival, so the
        // banner's distance is the distance to the destination itself.
        final engine = TurnByTurnEngine(
          straightRoute,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final nav = engine.update(
          LatLng(straightFixes.first.lat, straightFixes.first.lng),
          speedMps: 15,
        );
        expect(nav.meter, closeTo(nav.remainingMeters, 1));

    })();


    // ---- case: the turn-free route arrives at the end of its fixes ----
    (() {
        final engine = TurnByTurnEngine(
          straightRoute,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        var nav = engine.update(
          LatLng(straightFixes.first.lat, straightFixes.first.lng),
        );
        for (final f in straightFixes) {
          nav = engine.update(LatLng(f.lat, f.lng), speedMps: 15);
        }
        expect(nav.iconCode, iconArrive);
        expect(nav.remainingMeters, lessThan(50));

    })();
    });

  });

  group('the ahead/ near scans do not scale with route length', () {
    // The web has no isolate: `compute()` runs on the same thread, so a scan
    // that walks the whole polyline per item froze the page. On the 1 690 km
    // QL1A replay (84 532 vertices) one query measured 18.4 s and the drive
    // never caught up. `pointsAheadOnRoute` now scans only the stretch the
    // question can involve — these tests pin both the answer and the cost.
    final pts = <_Pt>[
      for (var i = 0; i < geom.length; i += 15)
        _Pt((geom[i][0] as num).toDouble(), (geom[i][1] as num).toDouble()),
    ];
    final at = LatLng(
      (geom[geom.length ~/ 2][0] as num).toDouble(),
      (geom[geom.length ~/ 2][1] as num).toDouble(),
    );
    const ahead = 1500.0;

    /// The pre-fix algorithm: project against the WHOLE polyline, per item.
    List<(int, double)> bruteForced() {
      const d = Distance();
      final f = nearestAlong(route.geometry, at);
      final out = <(int, double)>[];
      for (var i = 0; i < pts.length; i++) {
        final p = pts[i].pos;
        if (d.as(LengthUnit.Meter, at, p) > ahead + 500) continue;
        final t = nearestAlong(route.geometry, p);
        if (f == null || t == null) continue;
        final m = t - f;
        if (m >= 0 && m <= ahead) out.add((i, m));
      }
      out.sort((x, y) => x.$2.compareTo(y.$2));
      return out;
    }

    test('the windowed scan returns what the full scan returned', () {
      final fast = pointsAheadOnRoute<_Pt>((at, route.geometry, pts, ahead, 0));
      final slow = bruteForced();
      expect(fast.length, slow.length);
      for (var k = 0; k < fast.length; k++) {
        expect(fast[k].$1, slow[k].$1, reason: 'item $k');
        expect(fast[k].$2, closeTo(slow[k].$2, 1), reason: 'metres, item $k');
      }
    });

    test('and it stays cheap on the long route', () {
      final w = Stopwatch()..start();
      pointsAheadOnRoute<_Pt>((at, route.geometry, pts, ahead, 0));
      w.stop();
      // ignore: avoid_print
      print(
        'ahead scan: ${pts.length} items x ${geom.length} vertices → '
        '${w.elapsedMilliseconds}ms (full scan measured ~1 s in the VM)',
      );
      expect(w.elapsed, lessThan(const Duration(milliseconds: 300)));
    });
  });

  group('per-fix cost', () {
    test('does not grow with route length (the 2026-08-24 bug shape)', () {
      // The same road, decimated 16x: identical driving, a much shorter
      // polyline. A per-fix cost that scales with the geometry shows up here
      // as a ratio near the point ratio — this test measured 14.0x before the
      // fix and 0.7x after it.
      final shortGeom = [
        for (var i = 0; i < geom.length; i += 16) geom[i],
      ];
      final shortFixes = _drive(shortGeom, pace);
      final shortRoute = routeFromTrack(shortFixes);

      const n = 600;
      _sweepMicros(shortRoute, shortFixes, pace, n); // warm up the JIT
      final tShort = _sweepMicros(shortRoute, shortFixes, pace, n);
      final tLong = _sweepMicros(route, fixes, pace, n);
      final ratio = tLong / tShort;
      // ignore: avoid_print
      print(
        'per-fix cost: ${geom.length ~/ 16} points ${tShort}us vs '
        '${geom.length} points ${tLong}us → ${ratio.toStringAsFixed(2)}x '
        '(${(tLong / n).toStringAsFixed(2)}us per fix on the long route)',
      );
      expect(
        ratio,
        lessThan(6),
        reason:
            'per-fix cost is scaling with route length again — look for a '
            'full-geometry scan on the per-fix path',
      );
    });
  });
}


/// Minimal [OfflinePoint] for the scan tests (a camera/sign stand-in).
class _Pt implements OfflinePoint {
  final double lat;
  final double lng;
  _Pt(this.lat, this.lng);
  @override
  LatLng get pos => LatLng(lat, lng);
}
