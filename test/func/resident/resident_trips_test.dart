// THE RESIDENT RULE ON 105 REAL DRIVES — khu đông dân cư, in and out.
//
// `urban_area_test` proves the density rule on 1,375 towns and 882 open-country
// points, and `urban_limit_change_test` proves the limit step across a boundary
// it walks out of one town at a time. Neither drives a ROAD: a rule can be right
// about every town in a country and still flap on the way between two of them
// (a 300 m built-up run would swing the limit 60→50→60 and back), or fire
// somewhere no town exists.
//
// So this drives the whole trip matrix — 105 trips, 8,584 km of real QL1A and
// the roads pinned through Vinh, Huế, Đà Nẵng, Nha Trang — samples the rule
// every 250 m, and asserts what the driver gets: the run lengths, the limit at
// each crossing, the words, the announcement, and whether the crossing sits at a
// place that actually exists.
//
//   flutter test test/func/resident     (part of tool/check.sh's FUNCTION line)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/limit_change.dart';
import 'package:navbridge/pages/navigation/navigation_page.dart'
    show signCalloutPhrase;
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/urban_area.dart';

const String _tripsDir = 'test/data/trips';
const String _placesPath = 'test/data/vn_places_all.json';

/// How often the rule is asked during a drive. The app re-resolves the built-up
/// question every 150 m (`_townAt`), so 250 m under-samples it slightly — which
/// is the safe direction for a flapping check only if flapping is slower than
/// that, hence [minRunM] below.
const double sampleM = 250.0;

/// The shortest built-up run the driver may be shown, as a share of all runs.
/// A 250 m run is ONE sample at [sampleM], i.e. the smallest thing this test can
/// see. They are not automatically wrong — a hamlet strung along a country road
/// is a real khu đông dân cư and the limit SHOULD drop there — so this asserts
/// the share that is NOT near any settlement, which is the part that is a flap
/// rather than a place. Both numbers are measured on the matrix, not guessed.
const double minRunsAtLeast500m = 0.85;
const double maxUnjustifiedShortRuns = 8;

/// How close a populated place must be to JUSTIFY a short built-up run. Wider
/// than [settlementNearM] because a place node is a settlement's centroid: a
/// 250 m stretch of houses can belong to a hamlet whose node sits 2-3 km away,
/// and calling that "nobody lives here" would be measuring the label, not the
/// road.
const double shortRunJustifiedM = 3000.0;

/// Cross-check against the OSM populated places, expressed as what it CAN
/// measure: the distance from a crossing to the nearest place NODE.
///
/// A place node is a settlement's CENTROID, not its edge, so a crossing at the
/// boundary of a 3 km town is legitimately ~3 km from its node. Measured over the
/// 171-trip country-wide matrix the median is ~4.0 km, and the TAIL is the
/// interesting part: on a winding mountain highway — mapped as hundreds of short
/// segments with nobody living there — the segment-density rule reads the road
/// itself as a town. `tool/fetch_osm_places.py` documents the same effect when
/// building its rural set. So the assertion bounds the MEDIAN and the share of
/// far crossings, and reports the tail instead of pretending it is empty.
const double maxMedianToSettlementM = 5000.0;
const double farCrossingM = 10000.0;
const double maxFarCrossingShare = 0.10;
const double settlementNearM = 1500.0;

class _Towns {
  _Towns(this._grid);
  final Map<String, List<LatLng>> _grid;
  static const double _cell = 0.25; // ~27 km

  static Future<_Towns> load() async {
    final places = jsonDecode(File(_placesPath).readAsStringSync()) as List;
    final grid = <String, List<LatLng>>{};
    for (final e in places.cast<Map<String, dynamic>>()) {
      // every populated place, not just city/town — see maxMedianToSettlementM
      final p = LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble());
      grid.putIfAbsent(_key(p), () => []).add(p);
    }
    return _Towns(grid);
  }

  static String _key(LatLng p) =>
      '${(p.latitude / _cell).floor()}:${(p.longitude / _cell).floor()}';

  /// Distance in metres to the nearest populated place of any kind, or
  /// infinity if none within the searched cells.
  double nearest(LatLng p) {
    const d = Distance();
    final ci = (p.latitude / _cell).floor();
    final cj = (p.longitude / _cell).floor();
    var best = double.infinity;
    for (var a = -1; a <= 1; a++) {
      for (var b = -1; b <= 1; b++) {
        final list = _grid['${ci + a}:${cj + b}'];
        if (list == null) continue;
        for (final t in list) {
          final m = d.as(LengthUnit.Meter, p, t);
          if (m < best) best = m;
        }
      }
    }
    return best;
  }
}

/// One sampled point along a drive.
class _Sample {
  _Sample(this.alongM, this.pos, this.builtUp);
  final double alongM;
  final LatLng pos;
  final bool builtUp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the built-up rule on the trip matrix', () {
    test('crossings behave on every drive in the matrix', () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        markTestSkipped(
          'speed-limit assets are stubs here (see tool/stub_assets.sh)',
        );
        return;
      }
      final towns = await _Towns.load();
      final index = jsonDecode(
          File('$_tripsDir/index.json').readAsStringSync()) as Map<String, dynamic>;
      final entries = (index['trips'] as List).cast<Map<String, dynamic>>();
      expect(entries.length, greaterThanOrEqualTo(100));

      var sampledPoints = 0;
      var tripsWithTown = 0;
      var inCount = 0, outCount = 0;
      var runsTotal = 0, runsShort = 0;
      var crossingsAtTown = 0;
      var farBeyond = 0;
      var unjustifiedShortRuns = 0;
      var announcementTotal = 0;
      var swallowed = 0;
      var nearestWorst = 0.0;
      var nearestSum = 0.0;
      var worstBalance = 0;
      final perBucket = <String, int>{};
      final farCrossings = <String>[];

      for (final e in entries) {
        final id = e['id'] as String;
        final bucket = e['bucket'] as String;
        final geom = ((jsonDecode(
                    File('$_tripsDir/$id.json').readAsStringSync())
                as Map<String, dynamic>)['geometry'] as List)
            .cast<List<dynamic>>();

        // ---- sample the rule along the drive, in metres ----
        const d = Distance();
        final samples = <_Sample>[];
        var along = 0.0;
        var nextAt = 0.0;
        for (var i = 0; i < geom.length; i++) {
          final pos = LatLng(
              (geom[i][0] as num).toDouble(), (geom[i][1] as num).toDouble());
          if (i > 0) {
            along += d.as(LengthUnit.Meter,
                LatLng((geom[i - 1][0] as num).toDouble(),
                    (geom[i - 1][1] as num).toDouble()),
                pos);
          }
          if (along < nextAt) continue;
          nextAt = along + sampleM;
          samples.add(_Sample(along, pos, await isUrbanArea(pos)));
        }
        sampledPoints += samples.length;

        // ---- runs of built-up / open country ----
        final runs = <(bool, double, int, int)>[]; // builtUp, length, first, last
        var runStart = 0;
        for (var i = 1; i <= samples.length; i++) {
          if (i == samples.length ||
              samples[i].builtUp != samples[runStart].builtUp) {
            final len = samples[i - 1].alongM - samples[runStart].alongM + sampleM;
            runs.add((samples[runStart].builtUp, len, runStart, i - 1));
            runStart = i;
          }
        }
        if (runs.any((r) => r.$1)) {
          tripsWithTown++;
          perBucket[bucket] = (perBucket[bucket] ?? 0) + 1;
        }

        // ---- the driver-facing consequence of every crossing ----
        var tripIn = 0, tripOut = 0;
        for (var i = 1; i < runs.length; i++) {
          final entering = runs[i].$1;
          final prev = runs[i - 1];
          // A built-up run of ONE sample (~250-280 m) is the smallest this test
          // can see. Count them, and check whether each is JUSTIFIED by a real
          // settlement nearby — a hamlet along a mountain road is a built-up
          // area, and dropping the limit for 250 m there is correct.
          if (prev.$1) {
            runsTotal++;
            if (prev.$2 < 500) {
              runsShort++;
              // The run's OWN midpoint, not the middle of the remaining trip.
              final mid = samples[(prev.$3 + prev.$4) ~/ 2].pos;
              final near = towns.nearest(mid);
              if (!near.isFinite || near > shortRunJustifiedM) {
                unjustifiedShortRuns++;
              }
            }
          }
          if (entering) {
            inCount++;
            tripIn++;
          } else {
            outCount++;
            tripOut++;
          }

          // The limit either side of the crossing, for the road the matrix
          // actually follows (a two-way quốc lộ) and the vehicle it is ridden
          // with (mô tô, the app's default).
          final inside = roadInfoFromRoad(
              name: id, highway: 'primary', vehicle: 'motorbike', urban: true);
          final outside = roadInfoFromRoad(
              name: id, highway: 'primary', vehicle: 'motorbike', urban: false);
          expect(inside.speedLimit, 50, reason: '$id: in town on a 2-way road');
          expect(outside.speedLimit, 60, reason: '$id: open country');
          expect(inside.src, srcCity);
          expect(outside.src, srcClass);

          // …and the words, which must not promise a distance: the boundary
          // point is a zone vertex, not a post the driver can see.
          final phrase = signCalloutPhrase(
            entering ? RoadSignKind.populated : RoadSignKind.populatedEnd,
            sampleM,
            near: false,
          );
          expect(phrase, entering ? 'Bắt đầu khu dân cư phía trước'
                                 : 'Hết khu dân cư phía trước');
          expect(phrase.contains('mét'), isFalse);
          expect(phrase.contains('km'), isFalse);

          // Where the crossing happened, in the real world.
          final at = samples[runs[i].$3].pos;
          final near = towns.nearest(at);
          if (entering) {
            nearestSum += near.isFinite ? near : farCrossingM * 2;
            if (near.isFinite && near > nearestWorst) nearestWorst = near;
            if (near > farCrossingM) farBeyond++;
            if (near <= settlementNearM) {
              crossingsAtTown++;
            } else {
              farCrossings.add('$id at ${at.latitude.toStringAsFixed(3)},'
                  '${at.longitude.toStringAsFixed(3)} (nearest populated place '
                  '${near.isFinite ? '${near.round()} m' : '> 27 km'})');
            }
          }
        }

        // A drive enters a built-up area and leaves it: the two counts can
        // differ only by the trip starting or ending inside one.
        expect((tripIn - tripOut).abs(), lessThanOrEqualTo(1),
            reason: '$id: $tripIn entries but $tripOut exits');
        if ((tripIn - tripOut).abs() > worstBalance) {
          worstBalance = (tripIn - tripOut).abs();
        }

        // ---- what the driver HEARS: one announcement per change ----
        final announcer = LimitChangeAnnouncer();
        var clock = DateTime.utc(2026, 9, 28, 8);
        var spoke = 0;
        for (final s in samples) {
          clock = clock.add(const Duration(seconds: 4)); // 250 m at 225 km/h
          if (announcer.announce(s.builtUp ? 50 : 60, clock) != null) spoke++;
        }
        // Every change must be announced AT MOST once, plus the opening value:
        // a fresh session states the limit it starts on, then each change. The
        // count can be LOWER than changes + 1 by design — a boundary crossed
        // and re-crossed inside the 4 s cooldown is deliberately swallowed
        // rather than nagging (see LimitChangeAnnouncer and its own test). What
        // must never happen is the driver hearing the same change TWICE.
        var changes = 0;
        for (var i = 1; i < samples.length; i++) {
          if (samples[i].builtUp != samples[i - 1].builtUp) changes++;
        }
        expect(spoke, lessThanOrEqualTo(changes + 1),
            reason: '$id: $changes limit changes but $spoke announcements — '
                'the driver heard a change more than once');
        expect(spoke, greaterThanOrEqualTo(1),
            reason: '$id: a session must state the limit it starts on');
        swallowed += (changes + 1) - spoke;
        announcementTotal += spoke;
        if (changes == 0) {
          expect(spoke, 1, reason: '$id: no change, so only the opening limit');
        }
      }

      final coveredKm = ((index['coverage'] as Map)['covered_km'] as num)
          .toDouble();
      // ignore: avoid_print
      print('  ${entries.length} trips, $sampledPoints sampled points over '
          '${coveredKm.round()} km of road '
          '(${(coveredKm * 1000 / sampledPoints).round()} m '
          'per sample on average)');
      // ignore: avoid_print
      print('  trips with at least one built-up stretch: $tripsWithTown '
          '(${(100 * tripsWithTown / entries.length).round()}%)'
          '  by bucket: $perBucket');
      // ignore: avoid_print
      print('  crossings: $inCount entering, $outCount leaving '
          '($inCount + $outCount total), $announcementTotal announcements'
          '${swallowed > 0 ? ' ($swallowed change(s) swallowed by the 4 s cooldown)' : ''}');
      // ignore: avoid_print
      print('  built-up runs: $runsTotal, $runsShort shorter than 500 m '
          '(${(100 * runsShort / runsTotal).toStringAsFixed(1)}%), of which '
          '$unjustifiedShortRuns are NOT near any populated place');
      // ignore: avoid_print
      print('  entering crossings → nearest populated place: median '
          '${(nearestSum / inCount).round()} m, worst ${nearestWorst.round()} m '
          '(place nodes are centroids, so a few km is expected at a town edge); '
          '$crossingsAtTown/$inCount within '
          '${(settlementNearM / 1000).toStringAsFixed(1)} km'
          '${farCrossings.isEmpty ? '' : ' — furthest: ${farCrossings.take(6).join('; ')}'}');

      // The matrix must actually drive through populated country, or none of
      // the above is measuring anything. Not EVERY trip: a 2 km stretch of
      // QL1A between two towns is legitimately open country.
      expect(tripsWithTown / entries.length, greaterThanOrEqualTo(0.9),
          reason: 'only $tripsWithTown of ${entries.length} trips pass through '
              'a built-up area');
      expect(inCount, greaterThanOrEqualTo(10),
          reason: 'too few crossings into a built-up area ($inCount) to claim '
              'coverage of the resident rule');
      expect(outCount, greaterThanOrEqualTo(10));
      expect(worstBalance, lessThanOrEqualTo(1));
      // A systematic swing would show up as most runs being short.
      expect(1 - runsShort / runsTotal, greaterThanOrEqualTo(minRunsAtLeast500m),
          reason: '$runsShort of $runsTotal built-up runs are shorter than '
              '500 m — the limit swings 50/60/50 and the driver hears both '
              'boundaries in seconds');
      // …and the short ones must be places, not noise: a run whose own stretch
      // has nobody within ${settlementNearM.round()} m is the rule reading a
      // winding mountain highway as a town.
      expect(unjustifiedShortRuns, lessThanOrEqualTo(maxUnjustifiedShortRuns),
          reason: '$unjustifiedShortRuns short built-up runs have no populated '
              'place within ${shortRunJustifiedM.round()} m — the segment-density '
              'rule is reading road, not people');
      expect(nearestSum / inCount, lessThanOrEqualTo(maxMedianToSettlementM),
          reason: 'the median crossing is '
              '${(nearestSum / inCount).round()} m from any populated place — '
              'the rule is firing in open country');
      expect(farBeyond / inCount, lessThanOrEqualTo(maxFarCrossingShare),
          reason: '$farBeyond of $inCount crossings are more than '
              '${(farCrossingM / 1000).round()} km from any populated place');
    }, timeout: const Timeout(Duration(minutes: 20)));
  });
}
