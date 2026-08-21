/// Tests for the route-preference ranking (`offline_router.rankByPreference`)
/// and the preference model (`route_profile.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/offline_router.dart';
import 'package:navbridge/services/osrm.dart';

/// Build a synthetic route with [distance] m and [geometry]; [steps] controls
/// how many turn steps it claims (used by the "đường chính" avg-segment score).
OsrmRoute _route(double distance, List<LatLng> geometry, {int steps = 3}) {
  final seg = distance / (steps > 1 ? steps : 1);
  return OsrmRoute(
    distance: distance,
    duration: distance / 12,
    geometry: geometry,
    steps: [
      for (var i = 0; i < steps; i++)
        OsrmStep(
          name: 'Đường $i',
          distance: seg,
          duration: seg / 12,
          type: 'turn',
          modifier: 'straight',
          maneuver: geometry.isEmpty
              ? const LatLng(0, 0)
              : geometry[i % geometry.length],
        ),
    ],
  );
}

void main() {
  group('RoutePreference', () {
    test('labels are Vietnamese and distinct', () {
      expect(RoutePreference.fastest.label, 'Nhanh nhất');
      expect(RoutePreference.shortest.label, 'Ngắn nhất');
      expect(RoutePreference.mainRoads.label, 'Đường chính');
      expect(RoutePreference.scenic.label, 'Đẹp cảnh');
      final labels = kRoutePreferences.map((p) => p.label).toSet();
      expect(labels.length, kRoutePreferences.length);
    });

    test('every preference has a hint + icon', () {
      expect(kRoutePreferences.length, 4);
      for (final p in kRoutePreferences) {
        expect(p.hint, isNotEmpty);
        expect(p.icon, isNotNull);
      }
    });
  });

  group('rankByPreference', () {
    final straight = _route(4000, const [
      LatLng(10.0, 106.0),
      LatLng(10.0, 106.02),
      LatLng(10.0, 106.04),
    ]);
    final winding = _route(4000, const [
      LatLng(10.0, 106.0),
      LatLng(10.01, 106.01),
      LatLng(10.0, 106.02),
    ]);
    final short = _route(1200, const [
      LatLng(10.0, 106.0),
      LatLng(10.005, 106.005),
      LatLng(10.01, 106.01),
    ]);

    test('fastest keeps the backend order (duration-optimised)', () {
      final ranked = rankByPreference([
        short,
        winding,
      ], RoutePreference.fastest);
      expect(identical(ranked.first, short), isTrue);
    });

    test('shortest puts the smallest distance first', () {
      final ranked = rankByPreference([
        winding,
        short,
      ], RoutePreference.shortest);
      expect(identical(ranked.first, short), isTrue);
    });

    test('scenic puts the windiest polyline first', () {
      final ranked = rankByPreference([
        straight,
        winding,
      ], RoutePreference.scenic);
      expect(identical(ranked.first, winding), isTrue);
    });

    test('mainRoads prefers routes with longer average segments', () {
      final fewLegs = _route(10000, straight.geometry, steps: 2); // avg 5000
      final manyLegs = _route(10000, straight.geometry, steps: 5); // avg 2000
      final ranked = rankByPreference([
        manyLegs,
        fewLegs,
      ], RoutePreference.mainRoads);
      expect(identical(ranked.first, fewLegs), isTrue);
    });

    test('a single route is returned unchanged', () {
      final ranked = rankByPreference([short], RoutePreference.scenic);
      expect(ranked.length, 1);
      expect(identical(ranked.first, short), isTrue);
    });
  });
}
