// THE TRIP MATRIX — 185 trips that COVER VIETNAM, built by
// `tool/build_vietnam_trips.py`.
//
// Every trip is a stretch of real road chained from the `highway=trunk|primary`
// ways of the shipped extract: the ways are joined into continuous runs by
// shared endpoints, then cut so the trips spread over the country. Measured:
// 80% of the 0.5° grid cells that carry a national highway, all eight
// socio-economic regions, and a span from Cà Mau (8.6°N) to the northern
// mountains (23.3°N).
//
// Why this shape: the first version partitioned ONE route (Hà Nội → Sài Gòn).
// That is a single corridor — a rule can be right along QL1A and wrong in the
// Central Highlands, the Mekong delta or the northern mountains, and none of
// those would ever have been driven. Country-scale driving (a single 1,686 km
// route) is still covered by `long_trip_test` and `long_trip_limit_test`.
//
// What this catches that those cannot: a defect that only appears on some
// lengths, some terrain or some region — and the per-fix cost, which used to
// grow with route length (the 2026-08-24 ANR).
//
//   flutter test test/func/trip     (part of tool/check.sh's FUNCTION line)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/services/trip_replay.dart';

const String _indexPath = 'test/data/trips/index.json';

Map<String, dynamic> _index() =>
    jsonDecode(File(_indexPath).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _trip(String id) => jsonDecode(
      File('test/data/trips/$id.json').readAsStringSync(),
    ) as Map<String, dynamic>;

/// Fixes along the trip's geometry at its own pace, one per vertex, from a fixed
/// instant so a run is deterministic (same convention as `long_trip_test`).
List<ReplayFix> _drive(Map<String, dynamic> trip) {
  final geom = (trip['geometry'] as List).cast<List<dynamic>>();
  final pace = (trip['pace_mps'] as num).toDouble();
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
    out.add(ReplayFix(
      at: t0.add(Duration(microseconds: (cum / pace * 1e6).round())),
      lat: lat,
      lng: lng,
      accuracy: 10,
      speedMps: pace,
      headingDeg: heading,
    ));
  }
  return out;
}

/// True when the geometry revisits an exact coordinate — a retraced stretch
/// (the parent route does this once, at Huế: the waypoint that pins the route
/// through the city makes it drive in and out on the same 1 km of road).
bool _hasRepeatedCoordinate(List<List<dynamic>> geom) {
  final seen = <String>{};
  for (final p in geom) {
    final key = '${(p[0] as num).toDouble().toStringAsFixed(5)},'
        '${(p[1] as num).toDouble().toStringAsFixed(5)}';
    if (!seen.add(key)) return true;
  }
  return false;
}

void main() {
  final index = _index();
  final entries = (index['trips'] as List).cast<Map<String, dynamic>>();

  group('the trip matrix', () {
    test('is >= 100 trips in three length buckets, all real geometry', () {
      // The counts and the ranges are the contract this file tests against, so
      // a regeneration that silently drops or resizes a bucket fails here
      // rather than quietly weakening every test below.
      expect(entries.length, greaterThanOrEqualTo(100));
      final byBucket = <String, List<Map<String, dynamic>>>{};
      for (final e in entries) {
        byBucket.putIfAbsent(e['bucket'] as String, () => []).add(e);
      }
      expect(byBucket.keys.toSet(), {'short', 'mid', 'long'});
      expect(byBucket['short']!.length, greaterThanOrEqualTo(50));
      expect(byBucket['mid']!.length, greaterThanOrEqualTo(30));
      expect(byBucket['long']!.length, greaterThanOrEqualTo(25));

      const ranges = {
        'short': (1.5, 7.5),
        'mid': (9.5, 35.0),
        'long': (39.0, 150.0),
      };
      for (final e in entries) {
        final (lo, hi) = ranges[e['bucket']]!;
        final km = (e['km'] as num).toDouble();
        expect(km, inInclusiveRange(lo, hi), reason: '${e['id']} is $km km');
      }
    });

    test('the matrix COVERS VIETNAM, not one corridor', () {
      // The point of the matrix: geographic coverage. Every trip is a real
      // stretch of road somewhere in the country, so a rule that works on QL1A
      // and fails in Tây Nguyên has a trip that shows it. The earlier version
      // partitioned a single route — 105 trips up and down one highway, and
      // nothing else in the country driven at all.
      final coverage = index['coverage'] as Map<String, dynamic>;
      final cellsTouched = (coverage['coarse_cells_touched'] as num).toInt();
      final cellsWithRoads = (coverage['coarse_cells_with_roads'] as num).toInt();

      // 0.5° cells (~55 km) carrying a national highway.
      expect(
        cellsTouched / cellsWithRoads,
        greaterThanOrEqualTo(0.75),
        reason: 'only $cellsTouched of $cellsWithRoads highway cells have a '
            'trip through them — the matrix is clustering',
      );
      // …and the finer 0.25° grid as a second, stricter measure.
      expect((coverage['cells_touched'] as num).toInt(), greaterThanOrEqualTo(250),
          reason: 'the 0.25° spread collapsed');

      // Every region of the country, with real depth rather than one trip each.
      final regions = (coverage['regions'] as Map).cast<String, dynamic>();
      expect(regions.length, 8);
      for (final e in regions.entries) {
        expect((e.value as num).toInt(), greaterThanOrEqualTo(10),
            reason: '${e.key} has only ${e.value} trips');
      }

      // The span of the country: Cà Mau to the northern mountains, the Lao
      // border to the east coast. A corridor cannot do this.
      expect((coverage['lat_min'] as num).toDouble(), lessThan(9.5));
      expect((coverage['lat_max'] as num).toDouble(), greaterThan(22.5));
      expect((coverage['lng_min'] as num).toDouble(), lessThan(103.5));
      expect((coverage['lng_max'] as num).toDouble(), greaterThan(109.0));

      // No two trips are the same stretch of road.
      final starts = entries
          .map((e) => '${(e['endpoints'] as Map)['from']}')
          .toSet();
      expect(starts.length, entries.length,
          reason: 'two trips start at the same coordinate — a duplicate');
    });

    test('every trip yields a usable drive (>= 60 fixes, sane pace)', () {
      // The floor is 60, not a rounder number: short trips are resampled to
      // 20 m (so a 2 km trip is 100 fixes) while mid and long trips carry the
      // parent's own ~86 m vertices, and the shortest mid trip is 8 km = 73
      // fixes — a six-minute drive at the router's pace. What would NOT be a
      // drive is a handful of fixes, which is what this rejects.
      var minFixes = 1 << 30;
      for (final e in entries) {
        final trip = _trip(e['id'] as String);
        final fixes = _drive(trip);
        minFixes = fixes.length < minFixes ? fixes.length : minFixes;
        expect(fixes.length, greaterThanOrEqualTo(60),
            reason: '${e['id']} has only ${fixes.length} fixes');
        expect(fixes.first.at.isBefore(fixes.last.at), isTrue);
        for (final f in fixes) {
          expect(f.speedMps, greaterThan(0));
          expect(f.lat.isFinite && f.lng.isFinite, isTrue);
        }
      }
      // ignore: avoid_print
      print('  shortest drive in the matrix: $minFixes fixes');
    });

    test('every trip builds a route that matches its own geometry', () {
      var total = 0;
      for (final e in entries) {
        final trip = _trip(e['id'] as String);
        final fixes = _drive(trip);
        final route = routeFromTrack(fixes);
        final km = (e['km'] as num).toDouble();
        final driveS = (e['drive_s'] as num).toDouble();
        expect(route.geometry.length, fixes.length,
            reason: '${e['id']}: geometry rebuilt, not copied');
        // The slice's own length, from the parent's cumulative metres — the
        // route must agree with the fixture, not with itself.
        expect(route.distance, closeTo(km * 1000, km * 1000 * 0.02),
            reason: '${e['id']}: ${route.distance ~/ 1000} km vs $km km');
        expect(route.duration, closeTo(driveS, driveS * 0.05),
            reason: '${e['id']}: ${route.duration} s vs $driveS s');
        total += fixes.length;
      }
      // ignore: avoid_print
      print('  built ${entries.length} routes over $total fixes');
    });

    test('every trip drives from its first fix to its destination', () {
      // The country-scale failure this guards: the engine's cumulative length
      // used to run 0.07 % short, so the banner stopped at "1.2 km to go" and
      // the drive never arrived. On a 2 km trip that error is 1.4 m, on a
      // 338 km trip it is 237 m — so the check is on EVERY length.
      //
      // One exception, measured rather than assumed: the parent route RETRACES
      // a 1 km stretch at Huế (the waypoint pinned to route through the city
      // makes it drive in and out on the same road — vertices 7189-7237 repeat
      // at 7230-7278, identical coordinates). Where a trip contains such a
      // retraced stretch the car drives the same points twice, the nearest-point
      // match may land on the other leg, and the remaining distance rises by
      // that stretch's length exactly once. That is a property of the ROAD
      // (and of any nearest-point matcher), so the assertion is precise about
      // it instead of being loosened for every trip: retraced geometry is
      // detected by exact repeated coordinates, and only there may a single
      // increase of at most 1.5 km appear.
      var misses = 0;
      var retraced = 0;
      var retracedWithRise = 0;
      for (final e in entries) {
        final trip = _trip(e['id'] as String);
        final fixes = _drive(trip);
        final route = routeFromTrack(fixes);
        final hasRetrace = _hasRepeatedCoordinate(
            (trip['geometry'] as List).cast<List<dynamic>>());
        if (hasRetrace) retraced++;
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final start = engine.update(
            LatLng(fixes.first.lat, fixes.first.lng), speedMps: fixes.first.speedMps);
        expect(start.progress, lessThan(0.05), reason: '${e['id']} at the start');
        expect(start.remainingMeters, closeTo(route.distance, route.distance * 0.05),
            reason: '${e['id']} at the start');
        var prev = start.remainingMeters;
        var rises = 0;
        var worstRise = 0.0;
        for (final f in fixes) {
          final nav = engine.update(LatLng(f.lat, f.lng), speedMps: f.speedMps);
          expect(nav.remainingMeters.isFinite, isTrue, reason: '${e['id']} NaN');
          expect(nav.progress, inInclusiveRange(-0.001, 1.001),
              reason: '${e['id']}: progress ${nav.progress}');
          final rise = nav.remainingMeters - prev;
          if (rise > 1.0) {
            rises++;
            if (rise > worstRise) worstRise = rise;
          }
          prev = nav.remainingMeters;
        }
        if (hasRetrace) {
          expect(rises, lessThanOrEqualTo(1),
              reason: '${e['id']} retraces a stretch: at most ONE rise expected, '
                  'got $rises (worst ${worstRise.round()} m)');
          expect(worstRise, lessThanOrEqualTo(1500.0),
              reason: '${e['id']}: the retraced stretch is ~1 km, so a greater '
                  'rise means the match jumped somewhere else entirely');
          if (rises > 0) retracedWithRise++;
        } else {
          expect(rises, 0,
              reason: '${e['id']}: remaining distance went UP $rises times, '
                  'worst ${worstRise.toStringAsFixed(1)} m — and this trip has '
                  'no retraced geometry to explain it');
        }
        expect(prev, lessThan(60),
            reason: '${e['id']}: ${prev.toStringAsFixed(1)} m still to go');
        expect(engine.etaFactor, greaterThan(0));
        if (prev >= 60) misses++;
      }
      expect(misses, 0);
      // ignore: avoid_print
      print('  $retraced/${entries.length} trips contain a retraced stretch; '
          '$retracedWithRise of them show the single remaining-distance rise');
    });

    test('the per-fix cost does not grow with trip length (the 14x bug)', () {
      // 2026-08-24: the maneuver lookup scanned the WHOLE geometry 2-3x per fix,
      // so cost grew with route length — 14.0x on a route 16x longer. Compare
      // the first and last tenth of the drive on the LONGEST trips: a
      // regression makes the last tenth far slower than the first.
      final longs = entries.where((e) => e['bucket'] == 'long').toList()
        ..sort((a, b) => (b['km'] as num).compareTo(a['km'] as num));
      var worst = 0.0;
      for (final e in longs.take(3)) {
        final fixes = _drive(_trip(e['id'] as String));
        final route = routeFromTrack(fixes);
        final engine = TurnByTurnEngine(
          route,
          maxSpeedMps: RouteProfile.car.legalMaxMps,
        );
        final tenth = (fixes.length / 10).floor();
        double costOf(int from, int count) {
          final w = Stopwatch()..start();
          for (var k = from; k < from + count; k++) {
            engine.update(LatLng(fixes[k].lat, fixes[k].lng),
                speedMps: fixes[k].speedMps);
          }
          w.stop();
          return w.elapsedMicroseconds / count;
        }

        final early = costOf(0, tenth);
        final late = costOf(fixes.length - tenth, tenth);
        final ratio = late / early;
        // ignore: avoid_print
        print('  ${e['id']}: ${(e['km'] as num).toDouble().round()} km, '
            '${early.toStringAsFixed(1)} us/fix early → '
            '${late.toStringAsFixed(1)} us/fix late (${ratio.toStringAsFixed(2)}x)');
        if (ratio > worst) worst = ratio;
      }
      expect(worst, lessThan(3.0),
          reason: 'per-fix cost grew ${worst.toStringAsFixed(1)}x along the trip');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
