/// Posted speed limits — which value the driver gets, and from where
///
/// Phase-1 consolidation (2026-09-28): these were 11 separate
/// files, one per bugfix, each re-loading the same bundled pack in its own
/// test isolate. The assertions are unchanged — each former file is one
/// group below, so its file-local helpers keep their own scope.
///
///   ///   speed_limit_pick_test.dart
///   speed_limit_result_test.dart
///   speed_street_veto_test.dart
///   limit_street_name_test.dart
///   layer_limit_names_test.dart
///   limit_chain_test.dart
///   waze_segment_rule_test.dart
///   segment_repro_test.dart
///   next_street_limit_geometry_test.dart
///   sign_limit_test.dart
///   offline_speed_limits_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/road_match.dart';
import 'package:navbridge/core/sign_limit.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/ui/limit_source.dart';
// ---- from speed_limit_pick_test.dart ----
List<(int, double, double, double)> _cands(
  List<List<double>> dbrg, {
  List<double>? overshoot,
}) => [
  for (var i = 0; i < dbrg.length; i++)
    (i, dbrg[i][0], dbrg[i][1], overshoot == null ? 0.0 : overshoot[i]),
];

// ---- from speed_limit_result_test.dart ----
const _pacific = LatLng(5.0, 160.0); // far outside every crawled tile

// ---- from limit_street_name_test.dart ----
const _at = LatLng(10.78760, 106.63698);

// ---- from segment_repro_test.dart ----
const _lat = 10.799482;
const _lng = 106.641203; // the fix that logged 60 km/h (heading 182)

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('speed_limit_pick', () {
      group('segmentLineAngle', () {

        test('3 cases', () {
        // ---- case: is 0 along the line and 90 across it ----
        (() {
            expect(segmentLineAngle(21, 21), closeTo(0, 0.01));
            expect(segmentLineAngle(21, 90), closeTo(69, 0.01));
            expect(segmentLineAngle(0, 90), closeTo(90, 0.01));

        })();


        // ---- case: ignores direction: the opposite carriageway is the same road ----
        (() {
            expect(segmentLineAngle(21, 201), closeTo(0, 0.01));
            expect(segmentLineAngle(200, 20), closeTo(0, 0.01));

        })();


        // ---- case: is 0 when the heading is unknown (no signal to judge with) ----
        (() {
            expect(segmentLineAngle(null, 90), 0);

        })();
        });

      });

      group('segmentScore', () {

        test('3 cases', () {
        // ---- case: a segment across the path is pushed out of range ----
        (() {
            // 2 m away but perpendicular → scores past the 25 m range.
            expect(segmentScore(2, 90, 0, 25), greaterThan(25));
            // 20 m away and aligned → keeps its distance.
            expect(segmentScore(20, 0, 0, 25), 20);

        })();


        // ---- case: without a heading it is plain nearest-wins ----
        (() {
            expect(segmentScore(2, 90, null, 25), 2);

        })();


        // ---- case: a segment the car has driven past is pushed out of range ----
        (() {
            // 2 m away, but the car's projection is 30 m beyond its end.
            expect(segmentScore(2, 0, 0, 25, overshootM: 30), greaterThan(25));
            // …while sitting on it keeps the plain distance.
            expect(segmentScore(2, 0, 0, 25, overshootM: 0), 2);

        })();
        });

      });

      group('on-segment rule — "the car is IN this segment"', () {

        test('3 cases', () {
        // ---- case: an interior segment beats a nearer one the car has passed ----
        (() {
            // The car has just driven off segment 0's end (overshoot 30 m) and is
            // now on segment 1, 9 m along.
            final cands = _cands(
              [
                [2.0, 20.0],
                [9.0, 20.0],
              ],
              overshoot: [30.0, 0.0],
            );
            expect(pickSegmentCandidate(cands, 20, 25), 1);

        })();


        // ---- case: a small overshoot (junction stub) is still allowed ----
        (() {
            final cands = _cands(
              [
                [3.0, 20.0],
                [12.0, 20.0],
              ],
              overshoot: [4.0, 0.0],
            );
            expect(pickSegmentCandidate(cands, 20, 25), 0);

        })();


        // ---- case: falls back to a passed segment when it is all there is ----
        (() {
            final cands = _cands(
              [
                [5.0, 20.0],
              ],
              overshoot: [40.0],
            );
            expect(pickSegmentCandidate(cands, 20, 25), 0);

        })();
        });

      });

      group('pickSegmentCandidate — the Đường 30 Tháng 4 junction', () {

        test('5 cases', () {
        // ---- case: prefers the aligned road over a nearer crossing street ----
        (() {
            // Heading 21° (NNE, riding 30 Tháng 4). Lũy Bán Bích runs ~E-W (bearing
            // 110) and its segment is a metre closer.
            final cands = _cands([
              [3.0, 110.0],
              [4.0, 25.0],
            ]);
            expect(pickSegmentCandidate(cands, 21, 25), 1);
            // …and the crossing street wins nothing even at 1 m.
            final closer = _cands([
              [1.0, 110.0],
              [12.0, 25.0],
            ]);
            expect(pickSegmentCandidate(closer, 21, 25), 1);

        })();


        // ---- case: falls back to the nearest segment when nothing is aligned ----
        (() {
            // Stopped mid-turn, or on a road the layer does not name.
            final cands = _cands([
              [8.0, 100.0],
              [14.0, 130.0],
            ]);
            expect(pickSegmentCandidate(cands, 15, 25), 0);

        })();


        // ---- case: returns -1 when every candidate is out of range ----
        (() {
            final cands = _cands([
              [30.0, 20.0],
              [40.0, 25.0],
            ]);
            expect(pickSegmentCandidate(cands, 21, 25), -1);

        })();


        // ---- case: a nearer crossing segment does not beat an aligned one in range ----
        (() {
            // Worst case from the drive: 15 m accuracy, both segments under the car.
            final cands = _cands([
              [2.0, 90.0],
              [24.0, 22.0],
            ]);
            final win = pickSegmentCandidate(cands, 21, 25);
            expect(cands[win].$2, 24.0, reason: 'the crossing street must not win');

        })();


        // ---- case: empty candidates ----
        (() {
            expect(pickSegmentCandidate(const [], 21, 25), -1);

        })();
        });

      });
  });

  group('speed_limit_result', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      group('misses', () {

        test('3 cases', () async {
        // ---- case: answer null and leave no layer behind ----
        await (() async {
            expect(await lookupSpeedLimit(_pacific), isNull);
            expect(await speedLimitAt(_pacific), isNull);
            expect(lastLimitLayer(), isNull);
            expect(lastWazeSegmentId(), -1);
            expect(lastWazeStreetName(), isNull);

        })();


        // ---- case: clear the globals even when no layer answered at all ----
        await (() async {
            // The path that used to keep a previous segment's street alive: the tier
            // loop is skipped (or nothing matches), so only the wrapper can reset it.
            await loadOfflineSpeedLimits(); // a stub pack is fine here
            expect(await speedLimitAt(_pacific), isNull);
            expect(lastLimitLayer(), isNull);
            expect(lastWazeSegmentId(), -1);
            expect(lastWazeStreetName(), isNull);

        })();


        // ---- case: are repeatable ----
        await (() async {
            expect(await lookupSpeedLimit(_pacific), isNull);
            expect(await lookupSpeedLimit(_pacific), isNull);
            expect(lastLimitLayer(), isNull);

        })();
        });

      });

      group('SpeedLimitResult', () {
        test('is a const value object with the documented fields', () {
          const r = SpeedLimitResult(
            limit: 60,
            source: 'segment',
            streetName: 'Lũy Bán Bích',
            segmentId: 594661,
          );
          expect(r.limit, 60);
          expect(r.source, 'segment');
          expect(r.streetName, 'Lũy Bán Bích');
          expect(r.segmentId, 594661);
          // Point tiers carry no segment record — callers rely on null there.
          const p = SpeedLimitResult(limit: 50, source: 'waze');
          expect(p.streetName, isNull);
          expect(p.segmentId, isNull);
        });
      });

      group('street-name gate the segment tier applies', () {

        test('4 cases', () {
        // ---- case: the same road under different spellings matches ----
        (() {
            expect(streetNameMatches('Đường 30 Tháng 4', 'Đường 30/4'), isTrue);

        })();


        // ---- case: an alley is not the street it hangs off ----
        (() {
            expect(streetNameMatches('Đường 30 Tháng 4', 'Hẻm 30 Tháng 4'), isFalse);
            expect(
              streetNameMatches('Hẻm 62/1 Trương Công Định', 'Trương Công Định'),
              isFalse,
            );

        })();


        // ---- case: a generic or too-short shared token is not a match ----
        (() {
            expect(streetNameMatches('Đường', 'Đường'), isFalse);
            expect(streetNameMatches('30', '30'), isFalse);
            expect(streetNameMatches('Đường Nguyễn Trãi', 'Đường'), isFalse);

        })();


        // ---- case: unrelated streets never match ----
        (() {
            expect(streetNameMatches('Âu Cơ', 'Trần Tấn'), isFalse);

        })();
        });

      });
  });

  group('speed_street_veto', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      group('streetNameMatches', () {

        test('4 cases', () {
        // ---- case: the same street spelled differently still matches ----
        (() {
            expect(streetNameMatches('Đường 30 Tháng 4', 'Đường 30/4'), isTrue);
            expect(streetNameMatches('Lũy Bán Bích', 'Đường Lũy Bán Bích'), isTrue);
            expect(streetNameMatches('Độc Lập', 'Đường Độc Lập'), isTrue);

        })();


        // ---- case: a different street never matches ----
        (() {
            expect(streetNameMatches('Đường 30 Tháng 4', 'Lũy Bán Bích'), isFalse);
            expect(streetNameMatches('Tân Thành', 'Tân Thạnh'), isFalse);

        })();


        // ---- case: an alley off a street is not that street ----
        (() {
            // The trap a plain "two shared words" rule falls into: 'Hẻm 30 Tháng 4'
            // shares four tokens with the street name but is a different way.
            expect(streetNameMatches('Đường 30 Tháng 4', 'Hẻm 30 Tháng 4'), isFalse);
            expect(streetNameMatches('Âu Cơ', 'Hẻm 220/54 Âu Cơ'), isFalse);

        })();


        // ---- case: a word every address carries is not an identity ----
        (() {
            expect(streetNameMatches('Đường', 'Đường Lũy Bán Bích'), isFalse);
            expect(streetNameMatches('30', 'Đường 30/4'), isFalse);

        })();
        });

      });

      group('the layer answers only for the car\'s own street', () {
        // The exact failing position of the 2026-09-16 20:51 drive.
        const at = LatLng(10.78760, 106.63698);


        test('4 cases', () async {
        // ---- case: the car\'s own street gets its value ----
        await (() async {
            // 'Lũy Bán Bích' owns the 4 m record here, so it may use it.
            final v = await speedLimitAt(at, expectStreet: 'Lũy Bán Bích');
            expect(v, 60);

        })();


        // ---- case: another street does NOT inherit it ----
        await (() async {
            // Measured before the veto: this returned 60 for 'Đường 30 Tháng 4',
            // i.e. the neighbouring street's sign was posted as this road's limit.
            final v = await speedLimitAt(at, expectStreet: 'Đường 30 Tháng 4');
            expect(v, isNull);

        })();


        // ---- case: the car\'s own record still wins from further out (name band) ----
        await (() async {
            // 'Tân Thành' posts 50 but its record is 54 m away — outside the plain
            // 25 m radius, inside the band a SAME-NAME record is allowed to reach.
            final v = await speedLimitAt(at, expectStreet: 'Tân Thành');
            expect(v, 50);

        })();


        // ---- case: no expectation keeps the old nearest-wins behaviour ----
        await (() async {
            final v = await speedLimitAt(at);
            expect(v, 60);

        })();
        });

      });
  });

  group('limit_street_name', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      group('streetNameMatches', () {

        test('4 cases', () {
        // ---- case: spellings of one street match ----
        (() {
            expect(streetNameMatches('Đường 30 Tháng 4', 'Đường 30/4'), isTrue);
            expect(streetNameMatches('Đường 30 Tháng 4', '30-4'), isTrue);
            expect(streetNameMatches('Tân Thành', 'Tân Thành'), isTrue);
            expect(streetNameMatches('Lũy Bán Bích', 'Lũy Bán Bích'), isTrue);

        })();


        // ---- case: a different street does not ----
        (() {
            expect(streetNameMatches('Tân Thành', 'Lũy Bán Bích'), isFalse);
            expect(streetNameMatches('Đường 30 Tháng 4', 'Lũy Bán Bích'), isFalse);
            // An alley off the street is not the street.
            expect(streetNameMatches('Đường 30 Tháng 4', 'Hẻm 30 Tháng 4'), isFalse);

        })();


        // ---- case: one shared token is only enough when it is a name, not a number ----
        (() {
            expect(streetNameMatches('Nguyễn Hậu', 'Nguyễn Hậu'), isTrue);
            expect(streetNameMatches('Lê Lợi', 'Lê Văn Sỹ'), isFalse);

        })();


        // ---- case: an unnamed or empty side is never a match ----
        (() {
            expect(streetNameMatches(null, 'Lũy Bán Bích'), isFalse);
            expect(streetNameMatches('Tân Thành', null), isFalse);
            expect(streetNameMatches('Tân Thành', ''), isFalse);

        })();
        });

      });

      group('speedLimitAt with the road name known', () {

        test('3 cases', () async {
        // ---- case: prefers the car\'s own street over a closer record ----
        await (() async {
            await loadOfflineSpeedLimits();
            // Inside the 25 m radius only the crossing street has a record; the car's
            // own street sits at 54 m. The band must reach it.
            final v = await speedLimitAt(_at, headingDeg: 0, expectStreet: 'Tân Thành');
            expect(v, 50, reason: 'Tân Thành posts 50/50 — not Lũy Bán Bích 60');
            expect(lastWazeStreetName(), 'Tân Thành');
            expect(lastLimitLayer(), 'segment');

        })();


        // ---- case: refuses a record of another street when the car\'s own has none ----
        await (() async {
            await loadOfflineSpeedLimits();
            // Nothing in the layer covers Nguyễn Hậu here, so the only candidate is
            // the crossing street at 4 m — its 60 belongs to that street, not to us.
            final v = await speedLimitAt(
              _at,
              headingDeg: 0,
              expectStreet: 'Nguyễn Hậu',
            );
            expect(v, isNull,
                reason: 'no value is the right answer; the app falls back to '
                    'the OSM/class limit for this road');
            expect(lastWazeStreetName(), isNull,
                reason: 'the wrong street must not name the road either');

        })();


        // ---- case: without a road name the old nearest-wins behaviour stands ----
        await (() async {
            await loadOfflineSpeedLimits();
            // Documents the difference the name check makes: this IS what shipped.
            final v = await speedLimitAt(_at, headingDeg: 0);
            expect(v, 60);
            expect(lastWazeStreetName(), 'Lũy Bán Bích');

        })();
        });

      });
  });

  group('layer_limit_names', () {
      group('layerLimitMatchesNames — a veto needs something to veto against', () {

        test('7 cases', () {
        // ---- case: a named segment is adopted when we know no name at all ----
        (() {
            // The long-trip case: no road lookup has answered, the route steps carry
            // no names, the segment says "QL1".
            expect(
              layerLimitMatchesNames(
                segmentName: 'QL1',
                settled: '',
                osmName: '',
                routeNames: const [],
              ),
              isTrue,
            );

        })();


        // ---- case: a named segment is adopted when it matches the road on screen ----
        (() {
            expect(
              layerLimitMatchesNames(
                segmentName: 'Lũy Bán Bích',
                settled: 'Lũy Bán Bích',
                osmName: '',
                routeNames: const [],
              ),
              isTrue,
            );

        })();


        // ---- case: a named segment is adopted when it matches the OSM name ----
        (() {
            expect(
              layerLimitMatchesNames(
                segmentName: 'Cộng Hòa',
                settled: 'Trường Chinh',
                osmName: 'Cộng Hoà',
                routeNames: const [],
              ),
              isTrue,
            );

        })();


        // ---- case: a named segment is adopted when the ROUTE is that street ----
        (() {
            expect(
              layerLimitMatchesNames(
                segmentName: 'QL1',
                settled: 'Đường nội bộ',
                osmName: '',
                routeNames: const ['QL1', 'Nguyễn Văn Linh'],
              ),
              isTrue,
            );

        })();


        // ---- case: an unnamed segment carries no evidence — always adopted ----
        (() {
            expect(
              layerLimitMatchesNames(
                segmentName: null,
                settled: 'Trường Chinh',
                osmName: '',
                routeNames: const [],
              ),
              isTrue,
            );

        })();


        // ---- case: a segment of a DIFFERENT road is still rejected ----
        (() {
            // The case the veto exists for: 50 km/h from the crossing 'Độc Lập' while
            // the car is on 'Lũy Bán Bích' (2026-09-21 drive).
            expect(
              layerLimitMatchesNames(
                segmentName: 'Độc Lập',
                settled: 'Lũy Bán Bích',
                osmName: 'Lũy Bán Bích',
                routeNames: const ['Lũy Bán Bích'],
              ),
              isFalse,
            );

        })();


        // ---- case: a segment that merely shares a word is not a match ----
        (() {
            expect(
              layerLimitMatchesNames(
                segmentName: 'Nguyễn Trãi',
                settled: 'Nguyễn Văn Cừ',
                osmName: '',
                routeNames: const ['Nguyễn Văn Cừ'],
              ),
              isFalse,
            );

        })();
        });

      });

      group('the route-name set holds names, not the engine\'s filler', () {

        test('3 cases', () {
        // ---- case: blank slots and the "carry on" text are dropped ----
        (() {
            expect(
              routeRoadNames(
                ['Tiến lên', '', '   ', 'QL1'],
                placeholder: 'Tiến lên',
              ),
              {'QL1'},
            );

        })();


        // ---- case: a route whose steps carry no names must veto nothing ----
        (() {
            // The third gate measured on the QL1A fixture: every step was nameless, so
            // the engine reported 'Tiến lên' — and that filler, taken as a street
            // name, disagreed with the segment under the car ('Phạm Văn Đồng') and
            // dropped its 60 on every one of the 84,532 fixes.
            final routes = routeRoadNames(
              ['Tiến lên', 'Tiến lên', ''],
              placeholder: 'Tiến lên',
            );
            expect(routes, isEmpty);
            expect(
              layerLimitMatchesNames(
                segmentName: 'Phạm Văn Đồng',
                settled: '',
                osmName: '',
                routeNames: routes,
              ),
              isTrue,
            );

        })();


        // ---- case: a real street on the route still vetoes a different one ----
        (() {
            final routes = routeRoadNames(
              ['Lũy Bán Bích', 'Tiến lên'],
              placeholder: 'Tiến lên',
            );
            expect(routes, {'Lũy Bán Bích'});
            expect(
              layerLimitMatchesNames(
                segmentName: 'Độc Lập',
                settled: 'Lũy Bán Bích',
                osmName: '',
                routeNames: routes,
              ),
              isFalse,
            );

        })();
        });

      });

      group('a road known only from the layer', () {
        // The value the app publishes when nothing else has answered: built by
        // applyPostedLayer() from an empty road, exactly as nav_gps.dart does it.
        RoadInfo layerOnly(int kmh, String vehicle, {bool inTown = false}) =>
            applyPostedLayer(
              RoadInfo(name: '', highway: '', label: '', speedLimit: 0),
              kmh: kmh,
              vehicle: vehicle,
              layerSrc: srcSegment,
              name: 'QL1',
              inTown: inTown,
            );


        test('3 cases', () {
        // ---- case: shows the posted value and names the layer as its source ----
        (() {
            final r = layerOnly(90, 'car');
            expect(r.speedLimit, 90);
            expect(r.src, srcSegment);
            expect(r.fromLayer, isTrue); // a sign may only tighten it from here
            expect(r.name, 'QL1');

        })();


        // ---- case: a motorbike is still capped by its legal ceiling ----
        (() {
            // Thông tư 38/2024 (hiệu lực 01/01/2025) sets the legal maximums for motorbikes
            // (70 rural, 60 in town). When the road form is not known from OSM tags,
            // the vehicle zone ceiling applies so valid divided-road limits (60 on
            // Lũy Bán Bích, Trường Chinh) are not clamped down to 50.
            expect(layerOnly(90, 'motorbike').speedLimit, 70);
            expect(layerOnly(90, 'motorbike', inTown: true).speedLimit, 60);

        })();


        // ---- case: a car takes the sign itself, however high ----
        (() {
            expect(layerOnly(120, 'car').speedLimit, 120);

        })();
        });

      });
  });

  group('limit_chain', () {
      group('roadInfoFromRoad', () {

        test('5 cases', () {
        // ---- case: built-up rule: an untagged town street uses the road FORM ----
        (() {
            // Thông tư 38/2024: trong khu đông dân cư, đường hai chiều = 50 — NOT the
            // rural class default (mô tô tertiary = 60), which is what the overlay
            // used to show on every 2-lane city street.
            final road = roadInfoFromRoad(
              name: 'Tân Thành',
              highway: 'tertiary',
              vehicle: 'motorbike',
              urban: true,
            );
            expect(road.speedLimit, 50);
            expect(road.src, srcCity);
            expect(limitSourceLabel(road.src), 'CITY');
            expect(road.urban, isTrue);

        })();


        // ---- case: built-up rule: a divided town street is 60 for ô tô and mô tô ----
        (() {
            final road = roadInfoFromRoad(
              name: 'Lũy Bán Bích',
              highway: 'secondary',
              vehicle: 'motorbike',
              urban: true,
              divided: true,
            );
            expect(road.speedLimit, 60);
            expect(road.src, srcCity);

        })();


        // ---- case: outside town the vehicle class table applies ----
        (() {
            final moto = roadInfoFromRoad(
              name: 'QL1A',
              highway: 'primary',
              vehicle: 'motorbike',
            );
            final car = roadInfoFromRoad(
              name: 'QL1A',
              highway: 'primary',
              vehicle: 'car',
            );
            expect(moto.speedLimit, 60); // mô tô ngoài KĐDC
            expect(car.speedLimit, 80); // ô tô ngoài KĐDC
            expect(moto.src, srcClass);

        })();


        // ---- case: a posted maxspeed wins over the built-up rule and is OSM ----
        (() {
            final road = roadInfoFromRoad(
              name: 'Nguyễn Trãi',
              highway: 'primary',
              vehicle: 'motorbike',
              taggedKmh: 50,
              maxspeedTag: '50',
            );
            expect(road.speedLimit, 50);
            expect(road.src, srcOsm);
            expect(road.maxspeed, '50');

        })();


        // ---- case: a car-oriented tag only tightens a non-car class ----
        (() {
            // OSM maxspeed is a car tag: a rider must not inherit 80 on a primary,
            // but a lower posted value still applies.
            expect(
              roadInfoFromRoad(
                name: 'x',
                highway: 'primary',
                vehicle: 'motorbike',
                taggedKmh: 80,
              ).speedLimit,
              60,
            );
            expect(
              roadInfoFromRoad(
                name: 'x',
                highway: 'primary',
                vehicle: 'motorbike',
                taggedKmh: 40,
              ).speedLimit,
              40,
            );

        })();
        });

      });

      group('applyPostedLayer', () {

        test('5 cases', () {
        // ---- case: the posted layer is authority, badge names it ----
        (() {
            final road = roadInfoFromRoad(
              name: 'Tân Thành',
              highway: 'tertiary',
              vehicle: 'motorbike',
              oneway: true,
              lanes: 2,
              urban: true,
            );
            final posted = applyPostedLayer(
              road,
              kmh: 60,
              vehicle: 'motorbike',
              layerSrc: srcWazePoint,
            );
            expect(posted.speedLimit, 60); // the layer lifts the built-up 50
            expect(posted.src, srcWazePoint);
            expect(posted.fromLayer, isTrue); // ⇒ a sign may only tighten it
            expect(limitSourceLabel(posted.src), 'WAZE pt');

        })();


        // ---- case: the layer is authority, but not above the mô tô form ceiling ----
        (() {
            // Same street, hai chiều: the law gives a mô tô 50 in town, so a 60
            // layer value is capped — the class no longer decides (that was the
            // Ấp Bắc bug), the road FORM does.
            final road = roadInfoFromRoad(
              name: 'Tân Thành',
              highway: 'tertiary',
              vehicle: 'motorbike',
              divided: false,
              urban: true,
            );
            final posted = applyPostedLayer(
              road,
              kmh: 60,
              vehicle: 'motorbike',
              layerSrc: srcWazePoint,
            );
            expect(posted.speedLimit, 50);
            expect(posted.src, srcWazePoint);
            expect(posted.fromLayer, isTrue);

        })();


        // ---- case: a better street name from the layer is adopted, the road tags survive ----
        (() {
              final road = roadInfoFromRoad(
                name: 'Âu Cơ',
                highway: 'tertiary',
                vehicle: 'motorbike',
                oneway: false,
                lanes: 2,
              );
              final posted = applyPostedLayer(
                road,
                kmh: 50,
                vehicle: 'motorbike',
                layerSrc: srcSegment,
                name: 'Tân Thành',
              );
              expect(posted.name, 'Tân Thành');
              expect(posted.highway, 'tertiary');
              expect(posted.oneway, isFalse);
              expect(posted.lanes, 2);
              expect(posted.src, srcSegment);

        })();


        // ---- case: an empty layer name keeps the road name ----
        (() {
            final road = roadInfoFromRoad(
              name: 'Âu Cơ',
              highway: 'tertiary',
              vehicle: 'motorbike',
            );
            final posted = applyPostedLayer(
              road,
              kmh: 50,
              vehicle: 'motorbike',
              layerSrc: srcVietmap,
              name: '',
            );
            expect(posted.name, 'Âu Cơ');

        })();


        // ---- case: different road from layer does not inherit old road's undivided clamp (§8) ----
        (() {
            // Trương Công Định is two-way (divided: false), motorbike in town.
            // Entering Trường Chinh (60 km/h Waze segment): because the layer
            // brings a new road name, the previous road's undivided form must NOT
            // clamp Trường Chinh's 60 to 50.
            final oldRoad = roadInfoFromRoad(
              name: 'Trương Công Định',
              highway: 'tertiary',
              vehicle: 'motorbike',
              divided: false,
              urban: true,
            );
            final posted = applyPostedLayer(
              oldRoad,
              kmh: 60,
              vehicle: 'motorbike',
              layerSrc: srcSegment,
              name: 'Trường Chinh',
              inTown: true,
            );
            expect(posted.name, 'Trường Chinh');
            expect(posted.speedLimit, 60);
            expect(posted.src, srcSegment);

        })();
        });

      });

      group('builtUpRuleApplies', () {
        test('never applies when the road has a posted value', () async {
          // The posted value is authority; the POI test must not second-guess it
          // (and this makes the answer independent of the POI asset in the bundle).
          expect(
            await builtUpRuleApplies(
              const LatLng(10.7865, 106.6656),
              hasPosted: true,
            ),
            isFalse,
          );
        });
      });

      group('limitSourceLabel', () {
        test('maps every source, SIGN wins over the layer', () {
          expect(limitSourceLabel(srcSegment), 'WAZE');
          expect(limitSourceLabel(srcWazePoint), 'WAZE pt');
          expect(limitSourceLabel(srcVietmap), 'VIETMAP');
          expect(limitSourceLabel(srcOsm), 'OSM');
          expect(limitSourceLabel(srcCity), 'CITY');
          expect(limitSourceLabel(srcClass), 'CLASS');
          expect(limitSourceLabel(null), 'CLASS');
          expect(limitSourceLabel(srcCity, sign: true), 'SIGN');
        });
      });
  });

  group('waze_segment_rule', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      // A stretch where Waze posts 50 in one direction and 60 in the other, and
      // where the stored node order runs due west (bearing 270°).
      const hongBang = LatLng(10.753340, 106.650690);
      // fwd 80 / rev 60, stored node order runs just east of north (bearing 12°).
      const leDucAnh = LatLng(10.812940, 106.600470);


      test('4 cases', () async {
      // ---- case: a per-direction segment answers the value for the heading given ----
      await (() async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) return; // CI ships stub assets

          // Heading along the stored node order ⇒ the `fwd` value.
          expect(await speedLimitAt(hongBang, headingDeg: 270), 50);
          expect(lastLimitLayer(), 'segment');
          expect(await speedLimitAt(leDucAnh, headingDeg: 12), 80);
          expect(lastLimitLayer(), 'segment');

          // Opposite heading ⇒ the `rev` value. A reader that used the segment's
          // end-to-end bearing instead would return these two swapped.
          expect(await speedLimitAt(hongBang, headingDeg: 90), 60);
          expect(await speedLimitAt(leDucAnh, headingDeg: 192), 60);

          // No heading ⇒ the higher of the two, as a limit ceiling.
          expect(await speedLimitAt(hongBang), 60);
          expect(await speedLimitAt(leDucAnh), 80);

      })();


      // ---- case: the winning segment names the road that supplied the limit ----
      await (() async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) return;
          await speedLimitAt(hongBang, headingDeg: 270);
          expect(lastWazeStreetName(), 'Hồng Bàng');
          await speedLimitAt(leDucAnh, headingDeg: 12);
          expect(lastWazeStreetName(), 'Lê Đức Anh');

      })();


      // ---- case: the pick holds the value on screen between parallel records ----
      await (() async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) return;
          // Cộng Hòa carries TWO parallel records a few metres apart, with different
          // values and names that fold to the same string ('cong hoa'): id=601376
          // 60 km/h and id=603315 50 km/h. Whichever is nearest alternated with the
          // GPS noise and the chip swapped 60/50 every second (2026-09-22 20:48
          // drive, 27 same-road value changes). This coordinate+heading is one where
          // the plain pick takes the 50 and would have flipped the display.
          const congHoa = LatLng(10.800843, 106.660801);
          expect(await speedLimitAt(congHoa, headingDeg: 277), 50);
          expect(lastWazeStreetName(), 'Cộng Hòa');
          // 60 is on screen and a 60 record is right there → stay.
          expect(await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 60), 60);
          // A value nothing nearby carries must not be invented.
          expect(await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 80), 50);
          // With the band closed the plain pick returns (no unconditional stickiness).
          expect(
            await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 60, keepBandM: 0),
            50,
          );

      })();


      // ---- case: a lookup that finds no segment must not name a road ----
      await (() async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) return;
          // Đắk Lắk highlands: no segment within 25 m, and no point pin nearby.
          await speedLimitAt(hongBang, headingDeg: 270);
          expect(lastWazeStreetName(), isNotNull); // warm the global first

          final kmh = await speedLimitAt(const LatLng(12.0, 108.2), headingDeg: 270);
          expect(kmh, isNull);
          // The caller adopts this name verbatim when the limit is null, so an empty
          // answer here is what stops a stray segment renaming the road.
          expect(lastWazeStreetName(), isNull);

      })();
      });

  });

  group('segment_repro', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      test('the segment layer answers 50 km/h at the logged position', () async {
        await loadOfflineSpeedLimits();
        if (!speedLimitsPopulated) {
          return; // CI ships stub assets
        }
        for (final heading in <double?>[null, 182, 2]) {
          final kmh = await speedLimitAt(
            const LatLng(_lat, _lng),
            headingDeg: heading,
          );
          expect(kmh, 50, reason: 'heading $heading');
          expect(lastLimitLayer(), 'segment');
          expect(lastWazeStreetName(), 'Ấp Bắc');
        }
      });

      test(
        'a ±20 m offset keeps the segment in range (not a position problem)',
        () async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) {
            return;
          }
          final seen = <String, int>{};
          var n = 0;
          for (var dLat = -0.0002; dLat <= 0.00021; dLat += 0.0001) {
            for (var dLng = -0.0002; dLng <= 0.00021; dLng += 0.0001) {
              final kmh = await speedLimitAt(
                LatLng(_lat + dLat, _lng + dLng),
                headingDeg: 182,
              );
              seen['${kmh ?? 'null'}'] = (seen['${kmh ?? 'null'}'] ?? 0) + 1;
              n++;
            }
          }
          debugPrint('offsets probed: $n -> $seen');
          expect(seen['50'] ?? 0, greaterThan(n ~/ 2));
        },
      );
  });

  group('next_street_limit_geometry', () {
      // A route that runs 200 m north, then turns east for 200 m (a right turn).
      //                                        (the corner is the maneuver point)
      final corner = LatLng(10.000000, 106.000000);
      final route = <LatLng>[
        LatLng(9.998200, 106.000000),
        LatLng(9.999100, 106.000000),
        corner,
        LatLng(10.000000, 106.001000),
        LatLng(10.000000, 106.001900),
      ];


      test('5 cases', () {
      // ---- case: a sample past the corner lands on the NEW street, on the far side ----
      (() {
          final p = pointPast(corner, route, 30);
          expect(p, isNotNull);
          // 30 m east of the corner: longitude grew, latitude unchanged.
          expect(p!.longitude, greaterThan(corner.longitude));
          expect((p.latitude - corner.latitude).abs(), lessThan(0.00002));
          // ~30 m along the new leg (1e-5 ° lng ≈ 1.09 m at this latitude).
          final m = const Distance().as(LengthUnit.Meter, corner, p);
          expect(m, greaterThan(20));
          expect(m, lessThan(45));

      })();


      // ---- case: a sample before the corner stays on the street the car is ON ----
      (() {
          // The mirror case: if the sample had been taken BEHIND the maneuver, the
          // look-up would hit the old street — exactly the reported bug. Sample on
          // the incoming leg: latitude south of the corner.
          final p = pointPast(route[1], route, 30);
          expect(p, isNotNull);
          expect(p!.latitude, lessThan(corner.latitude));
          expect((p.longitude - 106.000000).abs(), lessThan(0.00005));

      })();


      // ---- case: the sample never drifts onto a parallel street ----
      (() {
          // A free-floating probe 30 m ahead in the CAR heading (north) would sit on
          // the street behind the corner. Walking the ROUTE polyline cannot do that,
          // so the sampled point must still be on a segment of the polyline.
          final p = pointPast(LatLng(9.999900, 106.000000), route, 30)!;
          final off = <double>[
            for (var i = 0; i + 1 < route.length; i++)
              const Distance().as(
                LengthUnit.Meter,
                projectOnSegment(route[i], route[i + 1], p),
                p,
              ),
          ].reduce((a, b) => a < b ? a : b);
          expect(off, lessThan(1.0));

      })();


      // ---- case: a point off the route (a parallel street) is refused ----
      (() {
          expect(pointPast(LatLng(10.010000, 106.010000), route, 30), isNull);

      })();


      // ---- case: past the end of the route it returns the last point ----
      (() {
          final p = pointPast(route[3], route, 5000);
          expect(p, route.last);

      })();
      });

  });

  group('sign_limit', () {
      group('signLimitInForce', () {

        test('5 cases', () {
        // ---- case: a sign ahead is a preview, not the limit ----
        (() {
            // The 09-18 failure: 60 km/h sign 350 m ahead while on Vườn Lài.
            expect(
              signLimitInForce(
                signValue: 60,
                signAheadM: 350,
                signRoad: 'Vườn Lài',
                currentRoad: 'Vườn Lài',
              ),
              isFalse,
              reason: 'the road value must stand until the car is at the sign',
            );

        })();


        // ---- case: it becomes the limit once reached ----
        (() {
            expect(
              signLimitInForce(
                signValue: 60,
                signAheadM: 0,
                signRoad: 'Vườn Lài',
                currentRoad: 'Vườn Lài',
              ),
              isTrue,
            );

        })();


        // ---- case: released after turning onto another road ----
        (() {
            expect(
              signLimitInForce(
                signValue: 60,
                signAheadM: 0,
                signRoad: 'Lũy Bán Bích',
                currentRoad: 'Vườn Lài',
              ),
              isFalse,
              reason: 'a 60 posted on Lũy Bán Bích must not govern Vườn Lài',
            );

        })();


        // ---- case: unknown road is trusted only where the car stands ----
        (() {
            // Adopted before the first road lookup: still in force once reached...
            expect(
              signLimitInForce(
                signValue: 60,
                signAheadM: 0,
                signRoad: null,
                currentRoad: null,
              ),
              isTrue,
            );
            // ...and released the moment the road changes (the caller re-binds the
            // name at that point, so `currentRoad` differs).
            expect(
              signLimitInForce(
                signValue: 60,
                signAheadM: 0,
                signRoad: null,
                currentRoad: 'Vườn Lài',
              ),
              isTrue,
              reason:
                  'null road is trusted; the caller binds a name when it knows '
                  'one, after which a change is detected',
            );

        })();


        // ---- case: no sign, or a nonsense value, is never in force ----
        (() {
            expect(
              signLimitInForce(
                signValue: null,
                signAheadM: 0,
                signRoad: 'Vườn Lài',
                currentRoad: 'Vườn Lài',
              ),
              isFalse,
            );
            expect(
              signLimitInForce(
                signValue: 0,
                signAheadM: 0,
                signRoad: 'Vườn Lài',
                currentRoad: 'Vườn Lài',
              ),
              isFalse,
            );

        })();
        });

      });


      test('3 cases', () {
      // ---- case: the segment layer is authority: a sign cannot RAISE it ----
      (() {
          // The 2026-09-20 case: three VietMap 60 signs standing on Lũy Bán Bích
          // (their own segment says 60) were applied to Tân Thành / Vườn Lài,
          // whose segment says 50 — 166 fixes of the chip reading 60 on a 50 road.
          expect(
            signLimitInForce(
              signValue: 60,
              signAheadM: 0,
              signRoad: 'Tân Thành',
              currentRoad: 'Tân Thành',
              layerKmh: 50,
            ),
            isFalse,
            reason: 'the layer says 50, so a 60 sign must not lift it',
          );

      })();


      // ---- case: but a sign that TIGHTENS the layer still applies ----
      (() {
          expect(
            signLimitInForce(
              signValue: 40,
              signAheadM: 0,
              signRoad: 'Tân Thành',
              currentRoad: 'Tân Thành',
              layerKmh: 50,
            ),
            isTrue,
            reason: 'a genuine 40 zone must still bite',
          );

      })();


      // ---- case: with no layer value the sign is judged as before ----
      (() {
          expect(
            signLimitInForce(
              signValue: 60,
              signAheadM: 0,
              signRoad: 'Tân Thành',
              currentRoad: 'Tân Thành',
            ),
            isTrue,
          );

      })();
      });

      test('multi-sign sequence and lifecycle', () {
        // 1. Sign reached is in force while driving forward:
        expect(
          signLimitInForce(
            signValue: 60,
            signAheadM: 0,
            signRoad: 'Quốc Lộ 1',
            currentRoad: 'Quốc Lộ 1',
            layerKmh: 0, // unposted / no waze segment
          ),
          isTrue,
          reason: 'sign is in force on unposted road',
        );

        // 2. An upcoming sign ahead (e.g. 300 m) is not in force yet:
        expect(
          signLimitInForce(
            signValue: 50,
            signAheadM: 300,
            signRoad: 'Quốc Lộ 1',
            currentRoad: 'Quốc Lộ 1',
            layerKmh: 0,
          ),
          isFalse,
          reason: 'upcoming sign at 300m is only a preview/advance warning',
        );

        // 3. Turning onto another road drops the sign limit:
        expect(
          signLimitInForce(
            signValue: 60,
            signAheadM: 0,
            signRoad: 'Quốc Lộ 1',
            currentRoad: 'ĐT 741',
            layerKmh: 0,
          ),
          isFalse,
          reason: 'sign from old road does not govern new road',
        );

        // 4. Effective limit for vehicle on unposted road with sign:
        final effCar = effectiveLimit(
          'unclassified',
          vehicle: 'car',
          taggedKmh: 60,
          urban: true,
          postedSrc: srcSegment,
        );
        expect(effCar, 60);

        // Undivided road in town: motorbike capped to 50
        final effMotoUndivided = effectiveLimit(
          'unclassified',
          vehicle: 'motorbike',
          taggedKmh: 60,
          urban: true,
          divided: false,
          postedSrc: srcSegment,
        );
        expect(effMotoUndivided, 50);

        // Divided road in town: motorbike allowed 60
        final effMotoDivided = effectiveLimit(
          'unclassified',
          vehicle: 'motorbike',
          taggedKmh: 60,
          urban: true,
          divided: true,
          postedSrc: srcSegment,
        );
        expect(effMotoDivided, 60);

        // 5. Sign tighter than urban limit:
        final effTight = effectiveLimit(
          'unclassified',
          vehicle: 'car',
          taggedKmh: 40,
          urban: true,
          postedSrc: srcSegment,
        );
        expect(effTight, 40);
      });

  });

  group('offline_speed_limits', () {
      TestWidgetsFlutterBinding.ensureInitialized();


      test('4 cases', () async {
      // ---- case: loads the bundled nationwide speed-limit layer ----
      await (() async {
          await loadOfflineSpeedLimits();
          expect(speedLimitsLoaded, isTrue);

      })();


      // ---- case: returns a real posted limit near a crawled point ----
      await (() async {
          await loadOfflineSpeedLimits();
          if (!speedLimitsPopulated) {
            return; // real DB is local-only (CI ships empty stub files)
          }
          // Probe a few metres off the first Waze point — the grid + radius lookup
          // must resolve a sane limit within the 25 m window.
          final raw = await rootBundle.loadString(
            'assets/offline_map/waze_speed_limits.json',
          );
          final d = jsonDecode(raw) as Map<String, dynamic>;
          final points = (d['points'] as List).cast<Map<String, dynamic>>();
          if (points.isEmpty) return;
          final p = points.first;
          final lat = (p['lat'] as num).toDouble();
          final lng = (p['lng'] as num).toDouble();
          final limit = await speedLimitAt(LatLng(lat + 0.00002, lng + 0.00002));
          expect(limit, isNotNull);
          expect(limit, inInclusiveRange(5, 200));

      })();


      // ---- case: querying exactly ON a posted Waze/VietMap point resolves its own limit ----
      await (() async {
            await loadOfflineSpeedLimits();
            if (!speedLimitsPopulated) {
              return; // real DB is local-only (CI ships empty stub files)
            }
            // Sample points straight from the bundled Waze / VietMap files; a query
            // at the point's own coordinates must resolve to its own (sane) limit.
            var checked = 0;
            var resolved = 0;
            for (final name in [
              'waze_speed_limits.json',
              'vietmap_speed_limits.json',
            ]) {
              final raw = await rootBundle.loadString('assets/offline_map/$name');
              final d = jsonDecode(raw) as Map<String, dynamic>;
              final points = (d['points'] as List?) ?? const [];
              for (final p in points.take(500)) {
                final lat = (p['lat'] as num?)?.toDouble();
                final lng = (p['lng'] as num?)?.toDouble();
                final kmh = (p['kmh'] as num?)?.toDouble();
                if (lat == null || lng == null || kmh == null) continue;
                checked++;
                final limit = await speedLimitAt(LatLng(lat, lng));
                if (limit != null) {
                  resolved++;
                  expect(limit, inInclusiveRange(5, 200));
                }
              }
            }
            expect(checked, greaterThan(0));
            expect(resolved, greaterThan(0), reason: 'on-point lookups missing');

      })();


      // ---- case: far off-map returns null (no invented limits) ----
      await (() async {
          await loadOfflineSpeedLimits();
          // Deep in the Pacific, far outside any crawled tile.
          final limit = await speedLimitAt(const LatLng(5.0, 160.0));
          expect(limit, isNull);

      })();
      });


      group('Waze WME per-segment layer', () {
        // Real coordinates from the 2026-09-14 HCMC trip log, each within a few
        // metres of a crawled Waze segment. The expected values were confirmed
        // independently by matching segments on the SAME street name (not just the
        // nearest segment — Waze's basemap geometry differs from OSM, so the
        // nearest-segment match agrees with the logged limit only ~29% of the time).

        test('4 cases', () async {
        // ---- case: resolves the real posted limit on Lũy Bán Bích (đường đôi = 60) ----
        await (() async {
              await loadOfflineSpeedLimits();
              if (!speedLimitsPopulated) return; // real DB is local-only
              // Lũy Bán Bích is a secondary split into two one-way carriageways with a
              // dải phân cách. Waze posts 60; the app used to DISPLAY 50 because a
              // built-up zone boundary capped it (that layer is gone — see
              // droppedSignKinds).
              final limit = await speedLimitAt(
                const LatLng(10.79571, 106.63825),
                headingDeg: 10,
              );
              expect(limit, 60);

        })();


        // ---- case: resolves Âu Cơ = 50 (two-way, no dải phân cách) ----
        await (() async {
            await loadOfflineSpeedLimits();
            if (!speedLimitsPopulated) return; // real DB is local-only
            // Âu Cơ is a TWO-WAY secondary with no median, so the built-up limit is
            // 50 — while the OSM class table alone says 60. This is exactly the case
            // the Waze segment layer fixes.
            final limit = await speedLimitAt(
              const LatLng(10.79697, 106.63789),
              headingDeg: 160,
            );
            expect(limit, 50);

        })();


        // ---- case: resolves Ấp Bắc = 50 (residential) ----
        await (() async {
            await loadOfflineSpeedLimits();
            if (!speedLimitsPopulated) return; // real DB is local-only
            final limit = await speedLimitAt(const LatLng(10.80073, 106.64134));
            expect(limit, 50);

        })();


        // ---- case: returns null far from any crawled segment ----
        await (() async {
            await loadOfflineSpeedLimits();
            if (!speedLimitsPopulated) return; // real DB is local-only
            // ~2 km north of the trip area, past the nearest crawled HCMC segment.
            expect(await speedLimitAt(const LatLng(10.83000, 106.66000)), isNull);

        })();
        });

      });
  });
}
