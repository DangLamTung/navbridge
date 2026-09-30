import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/trip_replay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> ready() async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped(
        'speed-limit assets are stubs here (see tool/stub_assets.sh)',
      );
      return false;
    }
    return true;
  }

  File? findTripFile() {
    final dir = Directory('docs/trips');
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.contains('083715')) {
        return entity;
      }
    }
    return null;
  }

  group('simulator trip speed limit vs Waze segment verification', () {
    test('trip 2026-09-29 08:37:15: Waze segments have valid data and displayed limits match segments',
        () async {
      if (!await ready()) return;

      final tripFile = findTripFile();
      if (tripFile == null) {
        // `docs/trips/` is gitignored on purpose: it holds the driver's own
        // recorded drives, which are not redistributed. CI therefore has no
        // recording to replay, and failing here would say "the code is broken"
        // about a file that was never meant to ship. The trips that must run
        // everywhere live in test/data/trips and are driven by the long-trip
        // suite next door.
        markTestSkipped(
          'no 2026-09-29 08:37 recording on this machine (docs/trips is '
          'gitignored — it is the driver\'s own trace)',
        );
        return;
      }

      final content = jsonDecode(tripFile.readAsStringSync()) as Map<String, dynamic>;
      final rawLocations = content['locations'] as List<dynamic>;
      expect(rawLocations, isNotEmpty);

      final fixes = parseReplayFixes(jsonEncode(rawLocations));
      expect(fixes.length, equals(386));

      int matchedFixes = 0;
      int uncorruptSegments = 0;
      final streetHits = <String, int>{};
      final streetLimits = <String, Set<int>>{};

      RoadInfo currentRoad = RoadInfo(
        name: '',
        highway: 'tertiary',
        label: '',
        speedLimit: 0,
      );

      for (var i = 0; i < fixes.length; i++) {
        final fix = fixes[i];
        final pos = LatLng(fix.lat, fix.lng);
        final hdg = fix.headingDeg == 0 ? null : fix.headingDeg;

        final hit = await lookupSpeedLimit(
          pos,
          headingDeg: hdg,
          keepKmh: currentRoad.speedLimit > 0 ? currentRoad.speedLimit : null,
        );

        if (hit == null) {
          continue;
        }

        matchedFixes++;

        // 1. Audit Waze segment data integrity ("no waze segment is wrongly data")
        expect(hit.source, equals('segment'));
        expect(hit.segmentId, isNotNull);
        expect(hit.segmentId!, greaterThan(0),
            reason: 'Fix $i: invalid segment ID');
        expect(hit.limit, greaterThan(0),
            reason: 'Fix $i: limit must be positive');
        expect(hit.limit, lessThanOrEqualTo(120),
            reason: 'Fix $i: limit exceeds 120 km/h');

        // All roads on this HCMC urban route are statutory 50 or 60 km/h.
        expect(
          hit.limit == 50 || hit.limit == 60,
          isTrue,
          reason: 'Fix $i on "${hit.streetName}": unexpected limit ${hit.limit} km/h (expected 50 or 60)',
        );

        uncorruptSegments++;

        final street = hit.streetName ?? '(unnamed)';
        streetHits[street] = (streetHits[street] ?? 0) + 1;
        streetLimits.putIfAbsent(street, () => <int>{}).add(hit.limit);

        // 2. Publish through road-limit pipeline (applyPostedLayer)
        final nextRoad = applyPostedLayer(
          currentRoad,
          kmh: hit.limit,
          vehicle: 'motorbike',
          layerSrc: hit.source,
          name: hit.streetName ?? currentRoad.name,
          inTown: true,
        );

        // 3. Verify the value shown is correct to the Waze segment
        expect(
          nextRoad.speedLimit,
          equals(hit.limit),
          reason: 'Fix $i on "$street": displayed limit ${nextRoad.speedLimit} '
              'differs from segment limit ${hit.limit}',
        );

        // Key street assertions along the drive:
        if (street.contains('Lũy Bán Bích')) {
          expect(hit.limit, equals(60), reason: 'Lũy Bán Bích Waze segment is 60 km/h');
          expect(nextRoad.speedLimit, equals(60), reason: 'Lũy Bán Bích displayed limit must be 60 km/h');
        } else if (street.contains('Ba Vân')) {
          expect(hit.limit, equals(50), reason: 'Ba Vân Waze segment is 50 km/h');
          expect(nextRoad.speedLimit, equals(50), reason: 'Ba Vân displayed limit must be 50 km/h');
        } else if (street.contains('Trương Công Định')) {
          expect(hit.limit, equals(50), reason: 'Trương Công Định Waze segment is 50 km/h');
          expect(nextRoad.speedLimit, equals(50), reason: 'Trương Công Định displayed limit must be 50 km/h');
        } else if (street.contains('Trường Chinh')) {
          expect(hit.limit, equals(60), reason: 'Trường Chinh Waze segment is 60 km/h');
          expect(nextRoad.speedLimit, equals(60), reason: 'Trường Chinh displayed limit must be 60 km/h (not clamped to 50)');
        } else if (street.contains('Ấp Bắc')) {
          expect(hit.limit, equals(50), reason: 'Ấp Bắc Waze segment is 50 km/h');
          expect(nextRoad.speedLimit, equals(50), reason: 'Ấp Bắc displayed limit must be 50 km/h');
        }

        currentRoad = nextRoad;
      }

      expect(matchedFixes, greaterThanOrEqualTo(280),
          reason: 'Expected >= 280 fixes to match Waze segments');
      expect(uncorruptSegments, equals(matchedFixes),
          reason: 'Every matched segment must have valid, clean data');

      // Verify each expected street was encountered with its exact limit:
      expect(streetLimits['Lũy Bán Bích'], equals({60}));
      expect(streetLimits['Ba Vân'], equals({50}));
      expect(streetLimits['Trương Công Định'], equals({50}));
      expect(streetLimits['Trường Chinh'], equals({60}));
      expect(streetLimits['Ấp Bắc'], equals({50}));

      // ignore: avoid_print
      print('Trip 083715 simulator verification:');
      // ignore: avoid_print
      print('  Total fixes: ${fixes.length}');
      // ignore: avoid_print
      print('  Matched Waze segment fixes: $matchedFixes');
      // ignore: avoid_print
      print('  Corrupt / invalid segments: 0');
      for (final entry in streetHits.entries) {
        // ignore: avoid_print
        print('  - ${entry.key}: ${entry.value} fixes, limits: ${streetLimits[entry.key]}');
      }
    });
  });
}
