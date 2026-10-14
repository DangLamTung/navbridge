import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/road_match.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/trip_replay.dart';

/// The 60↔50 flap on Lũy Bán Bích (2026-10-13 08:28 drive).
///
/// The limit on screen is written by TWO publishers, one after the other:
///   * `_withPostedLayer` — the road refresh (every 8 m), handed the road the
///     on-device graph matched;
///   * `_correctSpeedFromWazeInner` — the per-fix layer correction, handed the
///     road the app last PUBLISHED (whose `src` is the layer's).
///
/// The vehicle ceiling must be a property of the ROAD, not of whichever object
/// the writer happens to hold, so both must land on the same number. This test
/// drives the real segment layer over a real recording and asserts exactly that,
/// because when the two disagreed the chip alternated 60/50 on every fix —
/// 38 transitions over 1.0 km of a street whose Waze layer says 60 throughout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tripPath = 'assets/trips/2026-10-13_082850.json';

  test('the road refresh and the layer correction agree on every fix', () async {
    final file = File(tripPath);
    if (!file.existsSync()) {
      markTestSkipped('$tripPath is not in this checkout');
      return;
    }
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped(
        'speed-limit assets are stubs here (see tool/stub_assets.sh)',
      );
      return;
    }

    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final raw = (doc['locations'] as List?) ?? const <dynamic>[];
    final fixes = parseReplayFixes(jsonEncode(raw));
    expect(fixes, isNotEmpty, reason: '$tripPath must carry locations');

    // The road the drive itself was on, as the phone's graph would report it:
    // `name` / `highway` / `divided` from the recording, and NO `oneway` /
    // `lanes` — the shipped GraphHopper graph encodes neither, so the form is
    // unknown on the device (see formIsKnown).
    RoadInfo shown = RoadInfo(name: '', highway: '', label: '', speedLimit: 0);
    var disagreements = 0;
    final flipsByStreet = <String, int>{};
    var populated = 0;

    for (final f in fixes) {
      final hit = await lookupSpeedLimit(
        f.point,
        headingDeg: f.headingDeg == 0 ? null : f.headingDeg,
        keepKmh: shown.speedLimit > 0 ? shown.speedLimit : null,
      );
      if (hit == null || hit.limit <= 0) continue;
      populated++;

      final name = hit.streetName ?? f.street;
      final graphRoad = roadInfoFromRoad(
        name: f.street,
        highway: f.highway,
        vehicle: 'motorbike',
        divided: f.divided,
        urban: true,
      );

      // Writer 1: the road refresh (graph road in).
      final roadPath = applyPostedLayer(
        graphRoad,
        kmh: hit.limit,
        vehicle: 'motorbike',
        layerSrc: hit.source,
        name: name,
        inTown: true,
      );
      // Writer 2: the layer correction (the road we last published in).
      final wazePath = applyPostedLayer(
        shown,
        kmh: hit.limit,
        vehicle: 'motorbike',
        layerSrc: hit.source,
        name: name,
        inTown: true,
      );

      if (roadPath.speedLimit != wazePath.speedLimit) disagreements++;

      // …and the value on screen must not flip while the road does not change.
      final street = roadPath.name;
      if (shown.speedLimit > 0 &&
          roadPath.speedLimit != shown.speedLimit &&
          sameRoad(street, shown.name)) {
        flipsByStreet[street] = (flipsByStreet[street] ?? 0) + 1;
      }

      shown = roadPath;
    }

    expect(populated, greaterThan(300), reason: 'the layer must answer here');
    expect(
      disagreements,
      0,
      reason: 'the two publishers must derive the SAME ceiling; $disagreements '
          'fixes disagreed, which is the flap the driver sees',
    );
    // Lũy Bán Bích is the street from the report; its layer value is 60 on
    // every fix, so a same-road value change there is a defect by definition.
    expect(
      flipsByStreet['Lũy Bán Bích'] ?? 0,
      0,
      reason: 'Lũy Bán Bích must not flip: $flipsByStreet',
    );
  });
}
