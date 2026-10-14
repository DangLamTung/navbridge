// PER-STREET LIMIT + CALLOUT BASELINE for the shipped recorded trips.
//
// Captured from the 2026-10-13 build — the one that stopped holding a posted
// value on the chip after the car left the road it was posted on (see
// `_withPostedLayer` in nav_gps.dart), because the user reported "go from luỹ
// bán bích to thống nhất or some other street no waze, it keep 60 km/h".
//
// For every fix of every trip in `assets/trips/index.json` this walks the SAME
// in-process chain the app uses, so the baseline is re-derivable:
//   * `lookupSpeedLimit`      — the Waze / VIETMAP / DATMAP segment layer;
//   * `layerLimitMatchesNames`— is the winning segment the road under the car?
//   * `applyPostedLayer`      — the vehicle ceiling for that road;
//   * `roadInfoFromRoad`      — the road's OWN value, published when the layer
//                               has nothing (the option-1 behaviour this pins).
// Collapsing the per-fix values into runs gives the street list the driver
// actually sees, with the number on the chip and the callout wording for each.
//
// The golden lives in `test/data/street_baseline.json`. On the FIRST run (file
// absent) it is WRITTEN and the test passes, so a fresh checkout bootstraps
// itself — the same convention as `test/voice_phrase_fixture_test.dart`. Run it
// again and it asserts: any change to the chain now fails HERE, naming the trip.
//
//   flutter test test/func/limits/street_baseline_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/limit_change.dart';
import 'package:navbridge/core/road_match.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/trip_replay.dart';

const String _indexPath = 'assets/trips/index.json';
const String _goldenPath = 'test/data/street_baseline.json';

/// Per-fix entry collapse: only a run of the same (street, kmh, src) counts as
/// "the street the driver was on". A single-fix value is a candidate that never
/// settled, and pinning those would pin noise rather than the run.
const int _minRun = 3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('per-street limits and callouts match the captured baseline', () async {
    // ⭐ The bundled trips are NOT in git (`assets/trips/` is staged locally by
    // tool/sim_trips.py, and tool/stub_assets.sh does not recreate them), so a
    // clean checkout — CI — has no index to replay. SKIP, do not fail the build:
    // the same guard as test/func/trip/limit_flap_test.dart. Reading it blind
    // threw PathNotFoundException on CI while passing on every dev machine.
    final indexFile = File(_indexPath);
    if (!indexFile.existsSync()) {
      markTestSkipped('$_indexPath is not in this checkout');
      return;
    }

    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped(
        'speed-limit assets are stubs here (see tool/stub_assets.sh)',
      );
      return;
    }

    final index = jsonDecode(indexFile.readAsStringSync()) as List<dynamic>;
    final actual = <String, List<Map<String, Object?>>>{};

    for (final entry in index.cast<Map<String, dynamic>>()) {
      final ref = entry['ref'] as String;
      final file = File(ref);
      if (!file.existsSync()) continue; // a checkout without the fixture

      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final raw = (doc['locations'] as List?) ?? const <dynamic>[];
      final fixes = parseReplayFixes(jsonEncode(raw));
      if (fixes.isEmpty) continue;

      final perFix = <List<Object?>>[]; // [street, kmh, src]
      String? shownStreet;
      var shownKmh = 0;

      for (final f in fixes) {
        final sameAsShown =
            shownStreet != null && sameRoad(shownStreet, f.street);
        final hit = await lookupSpeedLimit(
          f.point,
          headingDeg: f.headingDeg == 0 ? null : f.headingDeg,
          keepKmh: sameAsShown && shownKmh > 0 ? shownKmh : null,
        );

        // The road the recording says the car was on — the phone's graph encodes
        // no `oneway`/`lanes`, so its form stays unknown (see formIsKnown).
        final road = f.street.trim().isEmpty
            ? null
            : roadInfoFromRoad(
                name: f.street,
                highway: f.highway.trim().isEmpty ? 'unclassified' : f.highway,
                vehicle: 'motorbike',
                divided: f.divided,
                urban: true,
              );

        // The layer may post its value only for the road under the car; when it
        // has nothing (or answers for another street) the road's OWN value is
        // published — never the value that was already on screen.
        final usable = hit != null &&
            hit.limit > 0 &&
            road != null &&
            layerLimitMatchesNames(
              segmentName: hit.streetName,
              settled: f.street,
              osmName: f.street,
              routeNames: const <String>[],
              ridden: hit.aligned,
            );

        final kmh = usable
            ? applyPostedLayer(
                road,
                kmh: hit.limit,
                vehicle: 'motorbike',
                layerSrc: hit.source,
                name: hit.streetName,
                inTown: true,
              ).speedLimit
            : (road?.speedLimit ?? 0);
        final name = usable ? (hit.streetName ?? f.street) : f.street;
        if (name.trim().isEmpty && kmh <= 0) continue;

        perFix.add([name, kmh, usable ? hit.source : 'road']);
        shownStreet = name;
        shownKmh = kmh;
      }

      // Collapse into the runs the driver actually sits through.
      final runs = <Map<String, Object?>>[];
      var i = 0;
      while (i < perFix.length) {
        var j = i;
        while (j + 1 < perFix.length &&
            perFix[j + 1][0] == perFix[i][0] &&
            perFix[j + 1][1] == perFix[i][1] &&
            perFix[j + 1][2] == perFix[i][2]) {
          j++;
        }
        final kmh = perFix[i][1] as int;
        if (j - i + 1 >= _minRun) {
          runs.add({
            'street': perFix[i][0],
            'kmh': kmh,
            'src': perFix[i][2],
            'callout': kmh > 0
                ? manoeuvreLimitPhrase((kmh: kmh, isNext: false)).trim()
                : '',
            'fixes': j - i + 1,
          });
        }
        i = j + 1;
      }

      actual[ref] = runs;
    }

    // The index can be present while every trip file it points at is not (a
    // half-staged tree): then there is nothing to pin, and comparing an empty
    // map against a captured baseline would fail for the wrong reason.
    if (actual.isEmpty) {
      markTestSkipped('no trip fixtures replayed here — nothing to pin');
      return;
    }

    final goldenFile = File(_goldenPath);
    if (!goldenFile.existsSync()) {
      goldenFile.parent.createSync(recursive: true);
      goldenFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(actual),
      );
      // ignore: avoid_print
      print('street baseline WRITTEN to $_goldenPath '
          '(${actual.length} trips) — commit it, then re-run to assert.');
      return;
    }

    final golden = jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
    expect(
      jsonDecode(jsonEncode(actual)),
      equals(golden),
      reason: 'the per-street limit chain changed — if that is intended, delete '
          '$_goldenPath and re-run to re-capture.',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
