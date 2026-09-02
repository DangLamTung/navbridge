import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/poi_search.dart';

void main() {
  // A straight route heading NORTH (lat increases) from (10.7, 106.6).
  final route = <LatLng>[
    const LatLng(10.70, 106.60),
    const LatLng(10.71, 106.60),
    const LatLng(10.72, 106.60),
    const LatLng(10.73, 106.60),
  ];

  test('projectOnRoute: ahead = positive, behind = negative', () {
    // 1 km north of start (car at start) → ~1 km ahead.
    final ahead = projectOnRoute(
      route,
      const LatLng(10.71, 106.60),
      startIndex: 0,
    );
    expect(ahead.aheadMeters, greaterThan(900));
    expect(ahead.aheadMeters, lessThan(1500));

    // South of start → behind (negative).
    final behind = projectOnRoute(
      route,
      const LatLng(10.69, 106.60),
      startIndex: 0,
    );
    expect(behind.aheadMeters, lessThan(0));
  });

  test('projectOnRoute: lateral side sign (left positive, right negative)', () {
    // Travel north; a point to the EAST (right side) → negative lateral.
    final right = projectOnRoute(
      route,
      const LatLng(10.71, 106.601), // ~100 m east
      startIndex: 0,
    );
    expect(right.lateralMeters, lessThan(0));

    // A point to the WEST (left side) → positive lateral.
    final left = projectOnRoute(
      route,
      const LatLng(10.71, 106.599),
      startIndex: 0,
    );
    expect(left.lateralMeters, greaterThan(0));
  });

  test('rankPoisForRoute prefers ahead + same side', () {
    final pois = <PoiResult>[
      // 1 km AHEAD, right side (ideal for right-hand traffic).
      PoiResult(name: 'best', lat: 10.71, lng: 106.601, type: PoiType.fuel),
      // 1 km AHEAD but LEFT side (needs crossing / U-turn).
      PoiResult(name: 'cross', lat: 10.71, lng: 106.599, type: PoiType.fuel),
      // BEHIND the car.
      PoiResult(name: 'behind', lat: 10.69, lng: 106.60, type: PoiType.fuel),
      // Far ahead (outside the 15 km window).
      PoiResult(name: 'far', lat: 10.90, lng: 106.60, type: PoiType.fuel),
    ];
    final ranked = rankPoisForRoute(pois, route, startIndex: 0);
    expect(ranked.first.name, 'best');
    expect(ranked.last.name, 'behind');
  });

  test('rankPoisForRoute: a station BEHIND the moving car ranks last', () {
    // Car is already ~2 km in (snapped at vertex 2). A station the car passed
    // (between 10.70 and 10.71) must read as NEGATIVE ahead and sink to the
    // bottom — not clamp onto the car's segment and "win" (the old bug that
    // made "xăng gần nhất" point back the way we came).
    final behind = PoiResult(
      name: 'behind',
      lat: 10.705,
      lng: 106.60,
      type: PoiType.fuel,
    );
    final proj = projectOnRoute(route, behind.pos, startIndex: 2);
    expect(proj.aheadMeters, lessThan(0));

    final pois = <PoiResult>[
      PoiResult(name: 'ahead', lat: 10.73, lng: 106.601, type: PoiType.fuel),
      behind,
    ];
    final ranked = rankPoisForRoute(pois, route, startIndex: 2);
    expect(ranked.first.name, 'ahead');
    expect(ranked.last.name, 'behind');
  });

  test('PoiType.cafeVong filters hammock-café names (unit)', () {
    expect(PoiType.cafeVong.nameFilter, isNotNull);
    final rx = RegExp(PoiType.cafeVong.nameFilter!, caseSensitive: false);
    expect(rx.hasMatch('Cà phê võng Bà Đông'), isTrue);
    expect(rx.hasMatch('Cafe Vong'), isTrue);
    expect(rx.hasMatch('Starbucks'), isFalse);
  });
}
