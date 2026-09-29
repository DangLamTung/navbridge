/// Does the SPEED LIMIT actually change when the driver crosses the built-up
/// boundary — and in the right direction?
///
/// `urban_area_test.dart` proves the rule calls real towns built-up and real
/// countryside open (1,375 + 882 OSM points). That says nothing about the
/// NUMBER the driver ends up seeing, which is `statutoryLimit` /
/// `urbanLimit` (Thông tư 38/2024) fed by that boolean. The two could each be
/// right and the pair still wrong — e.g. a town point that lowers a motorway
/// limit, or a boundary that shows 60 in town on a two-way street.
///
/// So this walks OUT of real towns on the bundled packs until the rule flips,
/// and asserts the limit on either side: a STEP up leaving town, never a step
/// down, and never an intermediate value.
///
///   flutter test test/func/resident/urban_limit_change_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/sign_limit.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/urban_area.dart';

const _urbanPath = 'test/data/vn_urban_osm.json';

/// Towns to walk out of. Each walk costs tens of pack lookups, and the walk
/// stops at the first bearing that reaches open country.
const int _sampleTowns = 8;

const double _stepM = 250.0;
const double _maxOutM = 12000.0;
const List<double> _bearings = [0.0, 90.0, 180.0, 270.0];

/// Measured 2026-09-28: 8/8 sampled towns leave the built-up area on the first
/// bearing within a few km. Floor is deliberately loose — the wall-clock cost of
/// a stubborn town is what it guards, not correctness.
const double _minLeaveRate = 0.7;

/// The classes a statutory limit is defined for. `statutoryLimit` falls back to
/// 50 for anything else, so an unknown class cannot be audited here.
const List<String> _classes = [
  'motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary',
  'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link',
  'unclassified', 'residential', 'living_street', 'service', 'pedestrian',
  'footway', 'cycleway',
];

/// The first point on [bearing] from [town] the rule calls open country, with
/// how far out it was. Null when every bearing stays built-up to [_maxOutM].
Future<(LatLng, double)?> _leaveTown(LatLng town) async {
  for (final bearing in _bearings) {
    for (var out = _stepM; out <= _maxOutM; out += _stepM) {
      final p = const Distance().offset(town, out, bearing);
      if (!await isUrbanArea(p)) return (p, out);
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('crossing the built-up boundary', () {
    test('entering town can never RAISE the limit for the same road', () {
      // The invariant the whole feature rests on: whatever the boundary does to
      // the boolean, the number it produces in town is never higher than the
      // one it produces in open country on the same road of the same form. A
      // table edit that broke this would tell a driver in a town they may go
      // FASTER than in a field.
      var checked = 0;
      for (final cls in _classes) {
        for (final vehicle in ['motorbike', 'car', 'truck']) {
          for (final divided in [false, true]) {
            final inTown = statutoryLimit(cls,
                vehicle: vehicle, urban: true, divided: divided);
            final outOfTown = statutoryLimit(cls,
                vehicle: vehicle, urban: false, divided: divided);
            expect(
              inTown,
              lessThanOrEqualTo(outOfTown),
              reason: '$vehicle on $cls '
                  '(${divided ? 'đường đôi' : 'hai chiều'}): '
                  'town $inTown must not exceed open country $outOfTown',
            );
            checked++;
          }
        }
      }
      expect(checked, _classes.length * 3 * 2);
    });

    test('the change is a STEP of the documented size, not a ramp', () {
      // Thông tư 38/2024 on a two-way quốc lộ: mô tô 50 in town → 60 outside
      // (the old code showed the rural 60 in town); xe tải 40 → 60.
      const road = 'primary';
      expect(
        statutoryLimit(road, vehicle: 'motorbike', urban: true),
        50,
      );
      expect(
        statutoryLimit(road, vehicle: 'motorbike', urban: false),
        60,
      );
      expect(
        statutoryLimit(road, vehicle: 'truck', urban: true),
        40,
      );
      expect(
        statutoryLimit(road, vehicle: 'truck', urban: false),
        60,
      );
      // Only two values exist for a mô tô on this road — nothing in between,
      // so a "part-way in town" limit cannot be shown by accident.
      final moto = {
        for (final divided in [false, true])
          for (final urban in [false, true])
            statutoryLimit(road,
                vehicle: 'motorbike', urban: urban, divided: divided),
      };
      expect(moto, {50, 60});
      expect(
        statutoryLimit(road,
            vehicle: 'motorbike', urban: true, divided: true),
        60,
        reason: 'in town a đường đôi is 60 — the value the Cộng Hòa fixes '
            'showed (2026-09-24)',
      );
      // The CLASS table is form-blind outside town: `urban: false` returns the
      // class default whatever the form, so the đường đôi 70 for a mô tô is not
      // a table row at all — it only ever comes from [vehicleCeiling] capping a
      // posted value. Pinned here because it is the asymmetry that made the
      // trunk row (car 90 / truck 70) look form-aware when it is not.
      expect(statutoryLimit(road, vehicle: 'motorbike', urban: false), 60);
      expect(
        statutoryLimit(road, vehicle: 'motorbike', urban: false, divided: true),
        60,
      );
      expect(vehicleCeiling('motorbike', divided: true), 70);
      expect(vehicleCeiling('motorbike'), 60);
    });

    test('walking out of a real town flips the rule AND raises the limit',
        () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        markTestSkipped(
          'speed-limit assets are stubs here (see tool/stub_assets.sh)',
        );
        return;
      }
      final towns = (jsonDecode(File(_urbanPath).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>()
          .take(_sampleTowns)
          .map((t) => (
                (t['name'] ?? '?') as String,
                LatLng((t['lat'] as num).toDouble(),
                    (t['lng'] as num).toDouble()),
              ))
          .toList();
      expect(towns, hasLength(_sampleTowns));

      var left = 0;
      final walked = <String>[];

      for (final (name, town) in towns) {
        // The fixture is towns, so the walk starts inside by construction —
        // if that fails the fixture and the rule disagree, which is its own bug.
        expect(await isUrbanArea(town), isTrue,
            reason: '$name is in the town fixture but the rule calls it rural');

        final out = await _leaveTown(town);
        if (out == null) {
          walked.add('$name: never left town within '
              '${(_maxOutM / 1000).round()} km — skipped');
          continue;
        }
        final (outside, meters) = out;
        left++;

        // The boundary in the driver's terms: the same two-way quốc lộ, before
        // and after. Untagged, so the built-up rule is what decides.
        final insideLimit = roadInfoFromRoad(
          name: name,
          highway: 'primary',
          vehicle: 'motorbike',
          urban: true,
        );
        final outsideLimit = roadInfoFromRoad(
          name: name,
          highway: 'primary',
          vehicle: 'motorbike',
          urban: false,
        );
        expect(insideLimit.speedLimit, 50,
            reason: '$name: ${meters.round()} m inside town');
        expect(outsideLimit.speedLimit, 60,
            reason: '$name: open country at '
                '${outside.latitude.toStringAsFixed(4)},'
                '${outside.longitude.toStringAsFixed(4)}');
        expect(outsideLimit.speedLimit, greaterThan(insideLimit.speedLimit),
            reason: '$name: leaving town must raise the limit');
        // Which table answered, not only the number: a 50 that came from the
        // rural class default would be right by accident.
        expect(insideLimit.src, srcCity);
        expect(outsideLimit.src, srcClass);

        walked.add('$name: limit 50 → 60 after ${meters.round()} m '
            '(${(meters / 1000).toStringAsFixed(1)} km)');
      }

      for (final line in walked) {
        // ignore: avoid_print
        print('  $line');
      }
      final rate = left / towns.length;
      // ignore: avoid_print
      print('  left town on the first bearing: $left/${towns.length} '
          '(${(rate * 100).round()}%)');
      expect(
        rate,
        greaterThanOrEqualTo(_minLeaveRate),
        reason: 'only $left of ${towns.length} sampled towns could be left '
            'within ${(_maxOutM / 1000).round()} km — the density rule is '
            'eating a ring of countryside around them',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('a posted limit is the SAME on both sides of the boundary', () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        markTestSkipped(
          'speed-limit assets are stubs here (see tool/stub_assets.sh)',
        );
        return;
      }
      final towns = (jsonDecode(File(_urbanPath).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      final hn = towns.firstWhere(
        (t) => ((t['name'] ?? '') as String).contains('H\u00e0 N\u1ed9i'),
        orElse: () => towns.first,
      );
      final pos = LatLng(
        (hn['lat'] as num).toDouble(),
        (hn['lng'] as num).toDouble(),
      );
      expect(await isUrbanArea(pos), isTrue,
          reason: '${hn['name']} must be a town for this test to mean anything');

      // A posted layer value is authority: [builtUpRuleApplies] must refuse to
      // apply the built-up table at all once something is posted, so crossing
      // the boundary cannot move the number.
      expect(await builtUpRuleApplies(pos, hasPosted: true), isFalse);
      expect(await builtUpRuleApplies(pos, hasPosted: false), isTrue);

      final road = roadInfoFromRoad(
        name: 'posted',
        highway: 'primary',
        vehicle: 'motorbike',
        taggedKmh: 50,
        maxspeedTag: '50',
        urban: true,
      );
      // A tag EQUAL to our own rule is not what decided the number: for a
      // motorbike an OSM maxspeed may only tighten, so the built-up table keeps
      // the credit and the chip does not advertise "osm" for its own guess.
      expect(road.speedLimit, 50);
      expect(road.src, srcCity);

      // A tag STRICTER than the rule is the tag's number, and is credited.
      final stricter = roadInfoFromRoad(
        name: 'school zone',
        highway: 'primary',
        vehicle: 'motorbike',
        taggedKmh: 40,
        maxspeedTag: '40',
        urban: true,
      );
      expect(stricter.speedLimit, 40);
      expect(stricter.src, srcOsm);
    });

    test('the layer keeps the limit ACROSS the boundary it posts through', () {
      // Same posted segment value, two contexts. The built-up rule must not
      // move it: a 60 posted on a divided street stands at 60 in town, and the
      // mô tô ceiling (not the town) is what caps it.
      final inTown = applyPostedLayer(
        RoadInfo(
          name: 'Cộng Hòa',
          highway: 'primary',
          label: 'Quốc lộ',
          speedLimit: 50,
          divided: true,
          urban: true,
          src: srcCity,
        ),
        kmh: 60,
        vehicle: 'motorbike',
        layerSrc: srcSegment,
        inTown: true,
      );
      final inField = applyPostedLayer(
        RoadInfo(
          name: 'ĐT724',
          highway: 'primary',
          label: 'Quốc lộ',
          speedLimit: 60,
          divided: false,
          urban: false,
          src: srcClass,
        ),
        kmh: 60,
        vehicle: 'motorbike',
        layerSrc: srcSegment,
        inTown: false,
      );
      expect(inTown.speedLimit, 60); // đường đôi in town — legal for a mô tô
      expect(inField.speedLimit, 60); // two-way in the countryside — legal too
      expect(inTown.src, srcSegment);
      expect(inField.src, srcSegment);
      // …and the pair differs by NOTHING, which is the point: the same posted
      // value survives the boundary.
      expect(inTown.speedLimit, inField.speedLimit);

      // The crossing DOES bite when the posted value exceeds the vehicle's
      // legal maximum for the road it is on: a 70 on a two-way town street.
      final capped = applyPostedLayer(
        RoadInfo(
          name: 'Tân Thành',
          highway: 'primary',
          label: 'Quốc lộ',
          speedLimit: 50,
          divided: false,
          urban: true,
          src: srcCity,
        ),
        kmh: 70,
        vehicle: 'motorbike',
        layerSrc: srcSegment,
        inTown: true,
      );
      expect(capped.speedLimit, 50, reason: 'mô tô hai chiều trong town = 50');
      expect(capped.src, srcSegment,
          reason: 'the layer still owns the number it posted');
      expect(capped.fromLayer, isTrue);
    });

    test('a speed sign in force still wins at the crossing', () {
      // Nothing about the built-up boundary suspends a sign the car has
      // reached: a 40 school zone inside town is 40, and a sign that would
      // RAISE the limit above the posted layer is refused.
      expect(
        signLimitInForce(
          signValue: 40,
          signAheadM: 10,
          signRoad: 'Tân Thành',
          currentRoad: 'Tân Thành',
          layerKmh: 50,
        ),
        isTrue,
      );
      expect(
        signLimitInForce(
          signValue: 70,
          signAheadM: 10,
          signRoad: 'Tân Thành',
          currentRoad: 'Tân Thành',
          layerKmh: 50,
        ),
        isFalse,
        reason: 'a sign may only tighten the posted layer, never raise it',
      );
      // Not reached yet → the boundary's own value still stands.
      expect(
        signLimitInForce(
          signValue: 40,
          signAheadM: kSignReachedM + 1,
          signRoad: 'Tân Thành',
          currentRoad: 'Tân Thành',
          layerKmh: 50,
        ),
        isFalse,
      );
    });
  });
}
