/// The speed-limit chain has ONE implementation again (overpass.dart).
///
/// These tests pin the behaviour the three call sites must share: the Overpass
/// road lookup, the on-device graph lookup and the standalone floating overlay
/// (see the `_selfRefresh` self-computed path). They drifted before — the
/// overlay kept the RURAL class default inside a town (60 on a 2-lane city
/// street) while the app showed 50 — so the cases below are the anti-drift net.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/ui/limit_source.dart';

void main() {
  group('roadInfoFromRoad', () {
    test('built-up rule: an untagged town street uses the road FORM', () {
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
    });

    test('built-up rule: a divided town street is 60 for ô tô and mô tô', () {
      final road = roadInfoFromRoad(
        name: 'Lũy Bán Bích',
        highway: 'secondary',
        vehicle: 'motorbike',
        urban: true,
        divided: true,
      );
      expect(road.speedLimit, 60);
      expect(road.src, srcCity);
    });

    test('outside town the vehicle class table applies', () {
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
    });

    test('a posted maxspeed wins over the built-up rule and is OSM', () {
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
    });

    test('a car-oriented tag only tightens a non-car class', () {
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
    });
  });

  group('applyPostedLayer', () {
    test('the posted layer is authority, badge names it', () {
      final road = roadInfoFromRoad(
        name: 'Tân Thành',
        highway: 'tertiary',
        vehicle: 'motorbike',
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
    });

    test(
      'a better street name from the layer is adopted, the road tags survive',
      () {
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
      },
    );

    test('an empty layer name keeps the road name', () {
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
}
