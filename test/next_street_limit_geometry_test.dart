/// The callout "rẽ trái vào X, tốc độ tối đa …" has to quote X — so the sample
/// point for X's limit must land PAST the maneuver, not on the street the car is
/// still driving on. That is [pointPast]'s whole job; user, 2026-09-24: "when
/// announcement, the next street speed is not correct, still taken from old
/// street".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_geo.dart';

void main() {
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

  test('a sample past the corner lands on the NEW street, on the far side', () {
    final p = pointPast(corner, route, 30);
    expect(p, isNotNull);
    // 30 m east of the corner: longitude grew, latitude unchanged.
    expect(p!.longitude, greaterThan(corner.longitude));
    expect((p.latitude - corner.latitude).abs(), lessThan(0.00002));
    // ~30 m along the new leg (1e-5 ° lng ≈ 1.09 m at this latitude).
    final m = const Distance().as(LengthUnit.Meter, corner, p);
    expect(m, greaterThan(20));
    expect(m, lessThan(45));
  });

  test('a sample before the corner stays on the street the car is ON', () {
    // The mirror case: if the sample had been taken BEHIND the maneuver, the
    // look-up would hit the old street — exactly the reported bug. Sample on
    // the incoming leg: latitude south of the corner.
    final p = pointPast(route[1], route, 30);
    expect(p, isNotNull);
    expect(p!.latitude, lessThan(corner.latitude));
    expect((p.longitude - 106.000000).abs(), lessThan(0.00005));
  });

  test('the sample never drifts onto a parallel street', () {
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
  });

  test('a point off the route (a parallel street) is refused', () {
    expect(pointPast(LatLng(10.010000, 106.010000), route, 30), isNull);
  });

  test('past the end of the route it returns the last point', () {
    final p = pointPast(route[3], route, 5000);
    expect(p, route.last);
  });
}
