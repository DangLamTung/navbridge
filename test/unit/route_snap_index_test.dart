/// The route snap runs ~30×/s for the car puck and once per camera on every
/// GPS fix, so it is indexed — these tests pin that the index answers exactly
/// what the full scan answers (the fast path must not move the puck).
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_snap.dart';

List<LatLng> _route(int n, {double stepDeg = 0.00005}) {
  // A wiggly line so cells are not all on one axis.
  return [
    for (var i = 0; i < n; i++)
      LatLng(
        10.70 + i * stepDeg,
        106.60 + i * stepDeg + 0.0002 * math.sin(i / 7),
      ),
  ];
}

void main() {
  test(
    'index matches the full scan on points on, beside and far from the route',
    () {
      final route = _route(4000);
      final idx = RouteSnapIndex(route);
      final rnd = math.Random(7);
      for (var k = 0; k < 400; k++) {
        final base = route[rnd.nextInt(route.length - 1)];
        // 0 m .. ~600 m away, in a random direction.
        final off = rnd.nextDouble() * 0.0055;
        final ang = rnd.nextDouble() * 2 * math.pi;
        final p = LatLng(
          base.latitude + off * math.cos(ang),
          base.longitude + off * math.sin(ang),
        );
        final full = nearestOnRoute(p, route);
        final fast = idx.nearest(p, maxDistanceM: 1e9);
        expect(
          fast.distanceM,
          closeTo(full.distanceM, 0.05),
          reason: 'distance mismatch at sample $k',
        );
        expect(
          (fast.point.latitude - full.point.latitude).abs(),
          lessThan(1e-7),
        );
        expect(
          (fast.point.longitude - full.point.longitude).abs(),
          lessThan(1e-7),
        );
      }
    },
  );

  test('snapToRoutePolyline and the index agree on the 40 m clamp', () {
    final route = _route(2000);
    final idx = RouteSnapIndex(route);
    final near = LatLng(route[1000].latitude + 0.0001, route[1000].longitude);
    expect(
      snapToRoutePolyline(near, route).latitude,
      closeTo(idx.nearest(near).point.latitude, 1e-9),
    );

    final far = LatLng(route[1000].latitude + 0.02, route[1000].longitude);
    expect(
      snapToRoutePolyline(far, route).latitude,
      far.latitude,
      reason: 'beyond the clamp the input point comes back unchanged',
    );
    expect(idx.nearest(far).point.latitude, far.latitude);
    expect(idx.nearest(far).distanceM, greaterThan(40));
  });

  test('nearestOnRoute reports the real distance (no 40 m clamp)', () {
    // Straight east-west line; the probe sits 100 m north of it.
    final route = [
      for (var i = 0; i < 20; i++) LatLng(10.80, 106.60 + i * 0.001),
    ];
    final off = LatLng(10.80 + 100.0 / 111320.0, 106.605);
    final r = nearestOnRoute(off, route);
    expect(r.distanceM, closeTo(100, 1));
    expect(r.point.latitude, closeTo(10.80, 1e-6));
  });

  test('a route shorter than two points is returned untouched', () {
    final idx = RouteSnapIndex([const LatLng(10, 106)]);
    final p = const LatLng(10.5, 106.5);
    expect(idx.nearest(p).point, p);
  });
}
