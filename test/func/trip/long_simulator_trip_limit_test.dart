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

  Map<String, dynamic> loadReplayTrip(String id) {
    // Check both served web replay path and test data path
    final servedPath = 'build/web/trips/$id.json';
    if (File(servedPath).existsSync()) {
      return jsonDecode(File(servedPath).readAsStringSync()) as Map<String, dynamic>;
    }
    final fixturePath = 'test/data/trips/$id.json';
    if (File(fixturePath).existsSync()) {
      return jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
    }
    throw StateError('Trip $id not found in build/web/trips or test/data/trips');
  }

  group('40km+ simulator trip limit & Waze segment validation', () {
    test('long_39 (42.3 km, QL51 / Xa lộ Hà Nội): segment data is 100% valid and displayed limits match',
        () async {
      if (!await ready()) return;

      final tripData = loadReplayTrip('long_39');
      final locs = (tripData['locations'] as List<dynamic>?) ?? [];
      expect(locs, isNotEmpty, reason: 'long_39 must have locations');

      final fixes = parseReplayFixes(jsonEncode(locs));
      expect(fixes.length, greaterThanOrEqualTo(1000),
          reason: 'long_39 has ~1,096 fixes');

      int matchedFixes = 0;
      int corruptSegments = 0;
      final streetHits = <String, int>{};
      final streetLimits = <String, Set<int>>{};

      RoadInfo currentCarRoad = RoadInfo(
        name: '',
        highway: 'primary',
        label: '',
        speedLimit: 0,
      );

      RoadInfo currentMotoRoad = RoadInfo(
        name: '',
        highway: 'primary',
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
          keepKmh: currentCarRoad.speedLimit > 0 ? currentCarRoad.speedLimit : null,
        );

        if (hit == null) {
          continue;
        }

        matchedFixes++;

        // 1. Audit Waze segment data integrity ("no waze segment is wrongly data")
        if (hit.segmentId == null ||
            hit.segmentId! <= 0 ||
            hit.limit <= 0 ||
            hit.limit > 120) {
          corruptSegments++;
        }

        expect(hit.source, equals('segment'));
        expect(hit.segmentId, isNotNull);
        expect(hit.segmentId!, greaterThan(0));
        expect(hit.limit, greaterThan(0));
        expect(hit.limit, lessThanOrEqualTo(120),
            reason: 'Fix $i: posted limit ${hit.limit} exceeds national maximum 120 km/h');

        final street = hit.streetName ?? '(unnamed)';
        streetHits[street] = (streetHits[street] ?? 0) + 1;
        streetLimits.putIfAbsent(street, () => <int>{}).add(hit.limit);

        // 2. Check CAR limit: Car takes the posted limit directly (up to 120)
        final nextCar = applyPostedLayer(
          currentCarRoad,
          kmh: hit.limit,
          vehicle: 'car',
          layerSrc: hit.source,
          name: hit.streetName ?? currentCarRoad.name,
          inTown: false,
        );

        expect(
          nextCar.speedLimit,
          equals(hit.limit),
          reason: 'Fix $i on "$street": car displayed limit ${nextCar.speedLimit} '
              'must match Waze segment ${hit.limit}',
        );

        // 3. Check MOTORBIKE limit: Must never exceed statutory ceiling (70 rural, 60 urban)
        final nextMoto = applyPostedLayer(
          currentMotoRoad,
          kmh: hit.limit,
          vehicle: 'motorbike',
          layerSrc: hit.source,
          name: hit.streetName ?? currentMotoRoad.name,
          inTown: false, // rural / suburban corridor
        );

        expect(
          nextMoto.speedLimit,
          lessThanOrEqualTo(70),
          reason: 'Fix $i on "$street": motorbike displayed limit ${nextMoto.speedLimit} '
              'exceeds statutory rural ceiling 70',
        );

        if (hit.limit <= 70) {
          expect(
            nextMoto.speedLimit,
            equals(hit.limit),
            reason: 'Fix $i on "$street": motorbike displayed limit should equal segment limit when <= 70',
          );
        }

        currentCarRoad = nextCar;
        currentMotoRoad = nextMoto;
      }

      expect(corruptSegments, equals(0), reason: '0 corrupt Waze segments');
      expect(matchedFixes, greaterThanOrEqualTo(1000),
          reason: 'Expected >= 1000 matched fixes on long_39');

      // Key corridor verification
      expect(streetHits.containsKey('QL51'), isTrue);
      expect(streetHits.containsKey('Xa lộ Hà Nội'), isTrue);

      // ignore: avoid_print
      print('long_39 (42.3 km) simulator verification:');
      // ignore: avoid_print
      print('  Total fixes: ${fixes.length}');
      // ignore: avoid_print
      print('  Matched Waze fixes: $matchedFixes');
      // ignore: avoid_print
      print('  Corrupt / invalid segments: $corruptSegments');
      for (final s in ['QL51', 'Xa lộ Hà Nội', 'Võ Nguyên Giáp']) {
        if (streetHits.containsKey(s)) {
          // ignore: avoid_print
          print('  - $s: ${streetHits[s]} fixes, limits: ${streetLimits[s]}');
        }
      }
    });

    test('long_46 (47.7 km): segment data is 100% valid and displayed limits match segments',
        () async {
      if (!await ready()) return;

      final tripData = loadReplayTrip('long_46');
      final locs = (tripData['locations'] as List<dynamic>?) ?? [];
      expect(locs, isNotEmpty);

      final fixes = parseReplayFixes(jsonEncode(locs));
      int matchedFixes = 0;
      int corruptSegments = 0;

      RoadInfo currentCarRoad = RoadInfo(
        name: '',
        highway: 'primary',
        label: '',
        speedLimit: 0,
      );

      for (var i = 0; i < fixes.length; i++) {
        final fix = fixes[i];
        final hit = await lookupSpeedLimit(
          LatLng(fix.lat, fix.lng),
          headingDeg: fix.headingDeg == 0 ? null : fix.headingDeg,
          keepKmh: currentCarRoad.speedLimit > 0 ? currentCarRoad.speedLimit : null,
        );

        if (hit == null) continue;
        matchedFixes++;

        if (hit.segmentId == null ||
            hit.segmentId! <= 0 ||
            hit.limit <= 0 ||
            hit.limit > 120) {
          corruptSegments++;
        }

        final nextCar = applyPostedLayer(
          currentCarRoad,
          kmh: hit.limit,
          vehicle: 'car',
          layerSrc: hit.source,
          name: hit.streetName ?? currentCarRoad.name,
          inTown: false,
        );

        expect(nextCar.speedLimit, equals(hit.limit));
        currentCarRoad = nextCar;
      }

      expect(corruptSegments, equals(0));
      expect(matchedFixes, greaterThanOrEqualTo(1000));

      // ignore: avoid_print
      print('long_46 (47.7 km) simulator verification:');
      // ignore: avoid_print
      print('  Total fixes: ${fixes.length}');
      // ignore: avoid_print
      print('  Matched Waze fixes: $matchedFixes');
      // ignore: avoid_print
      print('  Corrupt / invalid segments: $corruptSegments');
    });

    test('long_24 (69.5 km): segment data is 100% valid and displayed limits match segments',
        () async {
      if (!await ready()) return;

      final tripData = loadReplayTrip('long_24');
      final locs = (tripData['locations'] as List<dynamic>?) ?? [];
      expect(locs, isNotEmpty);

      final fixes = parseReplayFixes(jsonEncode(locs));
      int matchedFixes = 0;
      int corruptSegments = 0;

      RoadInfo currentCarRoad = RoadInfo(
        name: '',
        highway: 'primary',
        label: '',
        speedLimit: 0,
      );

      for (var i = 0; i < fixes.length; i++) {
        final fix = fixes[i];
        final hit = await lookupSpeedLimit(
          LatLng(fix.lat, fix.lng),
          headingDeg: fix.headingDeg == 0 ? null : fix.headingDeg,
          keepKmh: currentCarRoad.speedLimit > 0 ? currentCarRoad.speedLimit : null,
        );

        if (hit == null) continue;
        matchedFixes++;

        if (hit.segmentId == null ||
            hit.segmentId! <= 0 ||
            hit.limit <= 0 ||
            hit.limit > 120) {
          corruptSegments++;
        }

        final nextCar = applyPostedLayer(
          currentCarRoad,
          kmh: hit.limit,
          vehicle: 'car',
          layerSrc: hit.source,
          name: hit.streetName ?? currentCarRoad.name,
          inTown: false,
        );

        expect(nextCar.speedLimit, equals(hit.limit));
        currentCarRoad = nextCar;
      }

      expect(corruptSegments, equals(0));
      expect(matchedFixes, greaterThanOrEqualTo(1500));

      // ignore: avoid_print
      print('long_24 (69.5 km) simulator verification:');
      // ignore: avoid_print
      print('  Total fixes: ${fixes.length}');
      // ignore: avoid_print
      print('  Matched Waze fixes: $matchedFixes');
      // ignore: avoid_print
      print('  Corrupt / invalid segments: $corruptSegments');
    });
  });
}
