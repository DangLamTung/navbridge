/// Tests for the turn-by-turn engine (`nav_engine.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/osrm.dart';

/// A straight ~1.1 km eastbound route with 101 geometry points (~11 m apart)
/// and two steps: depart + arrive.
OsrmRoute _straightRoute() {
  const lat = 10.8231;
  const lng = 106.6297;
  final geometry = <LatLng>[
    for (var i = 0; i <= 100; i++) LatLng(lat, lng + i * 0.0001),
  ];
  return OsrmRoute(
    distance: 1110,
    duration: 80,
    geometry: geometry,
    steps: [
      OsrmStep(
        name: 'Đường A',
        distance: 1110,
        duration: 80,
        type: 'depart',
        modifier: null,
        maneuver: geometry.first,
      ),
      OsrmStep(
        name: 'Bến Thành',
        distance: 0,
        duration: 0,
        type: 'arrive',
        modifier: null,
        maneuver: geometry.last,
      ),
    ],
    stopCumulative: const [1110],
  );
}

void main() {
  group('TurnByTurnEngine', () {
    test('positionAtDistance clamps to the polyline ends', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final route = _straightRoute();
      expect(engine.positionAtDistance(-10), route.geometry.first);
      expect(engine.positionAtDistance(1e9), route.geometry.last);
    });

    test('positionAtDistance interpolates along the route', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final mid = engine.positionAtDistance(500);
      expect(mid.latitude, closeTo(10.8231, 1e-6));
      expect(mid.longitude, greaterThan(106.6297));
      expect(mid.longitude, lessThan(106.72));
    });

    test('update returns the first step near the start', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final nav = engine.update(_straightRoute().geometry.first);
      expect(nav.iconCode, iconStraight);
      expect(nav.meter, greaterThan(0));
      expect(nav.progress, lessThan(0.05));
      expect(nav.totalStops, 1);
      expect(nav.stopIndex, 0);
      expect(nav.stopName, '');
    });

    test('update advances to arrive at the route end', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final route = _straightRoute();
      engine.update(route.geometry.first);
      final nav = engine.update(route.geometry.last);
      expect(nav.iconCode, iconArrive);
      expect(nav.meter, 0);
      expect(nav.progress, greaterThan(0.9));
    });

    test('currentCumulative advances along the route', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final route = _straightRoute();
      engine.update(route.geometry.first);
      final startCum = engine.currentCumulative;
      engine.update(engine.positionAtDistance(400));
      expect(engine.currentCumulative, greaterThan(startCum));
    });

    test('offRouteDistance detects points far from the route', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final route = _straightRoute();
      expect(engine.offRouteDistance(route.geometry.first), lessThan(20));
      // ~1.1 km north of the route.
      final far = LatLng(10.8231 + 0.01, 106.6297);
      expect(engine.offRouteDistance(far), greaterThan(900));
    });

    test('multi-stop routes report the approaching stop', () {
      final base = _straightRoute();
      final route = OsrmRoute(
        distance: base.distance,
        duration: base.duration,
        geometry: base.geometry,
        steps: base.steps,
        stopCumulative: const [300, 600, 1110],
      );
      final engine = TurnByTurnEngine(route, stopNames: const ['A', 'B', 'C']);
      engine.update(base.geometry.first);
      // ~400 m in → approaching stop #2.
      final nav = engine.update(engine.positionAtDistance(400));
      expect(nav.totalStops, 3);
      expect(nav.stopIndex, 1);
      expect(nav.stopName, 'B');
      // At the very end → last stop.
      final end = engine.update(route.geometry.last);
      expect(end.stopIndex, 2);
      expect(end.stopName, 'C');
    });

    test('snapToRoute projects a fix beside the road onto the route', () {
      final engine = TurnByTurnEngine(_straightRoute());
      // Raw GPS fix ~30 m north of the road, beside the middle of it.
      final off = LatLng(10.8231 + 0.00027, 106.6350);
      final snapped = engine.snapToRoute(off);
      // The projection lands back on the road line (lat ≈ road lat).
      expect(snapped.latitude, closeTo(10.8231, 1e-6));
      // And it's ~30 m from the raw fix → back on the polyline.
      expect(distanceMeters(off, snapped), closeTo(30, 5));
      expect(engine.offRouteDistance(snapped), lessThan(15));
    });

    test('snapToRoute picks the nearest segment, not the nearest vertex', () {
      // L-shaped route: east then south.
      final geometry = [
        const LatLng(10.82, 106.62),
        const LatLng(10.82, 106.64),
        const LatLng(10.80, 106.64),
      ];
      final engine = TurnByTurnEngine(
        OsrmRoute(
          distance: 4000,
          duration: 300,
          geometry: geometry,
          steps: const [],
        ),
      );
      // Fix north of the east-west leg → snaps onto that leg, before the bend.
      final off = LatLng(10.8202, 106.63);
      final snapped = engine.snapToRoute(off);
      expect(snapped.latitude, closeTo(10.82, 1e-6));
      expect(snapped.longitude, closeTo(106.63, 1e-5));
      // Fix west of the north-south leg → snaps onto that leg, after the bend.
      final off2 = LatLng(10.81, 106.6402);
      final snapped2 = engine.snapToRoute(off2);
      expect(snapped2.longitude, closeTo(106.64, 1e-6));
      expect(snapped2.latitude, closeTo(10.81, 1e-5));
    });

    test('snapToRoute clamps beyond the ends to the route ends', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final route = _straightRoute();
      // Far past the destination → clamps to the last polyline point.
      final past = LatLng(10.8231, 106.75);
      expect(engine.snapToRoute(past), route.geometry.last);
      // Far before the origin → clamps to the first point.
      final before = LatLng(10.8231, 106.55);
      expect(engine.snapToRoute(before), route.geometry.first);
    });

    test(
      'update text is the current road and nextText is the incoming road',
      () {
        final route = _straightRoute();
        final engine = TurnByTurnEngine(route);
        final nav = engine.update(engine.positionAtDistance(100));
        // On 'Đường A', the upcoming step's road (the street you turn into)
        // is the destination 'Bến Thành'.
        expect(nav.text, 'Đường A');
        expect(nav.nextText, 'Bến Thành');
      },
    );

    test(
      'snapToRoute advances snappedSegmentIndex as the route is consumed',
      () {
        final engine = TurnByTurnEngine(_straightRoute());
        expect(engine.snappedSegmentIndex, 0);
        // Near the start (~10 m in, ~1 vertex).
        engine.snapToRoute(engine.positionAtDistance(10));
        final startSeg = engine.snappedSegmentIndex;
        expect(startSeg, lessThan(5));
        // Mid-route (~600 m in, ~55 vertices of ~11 m).
        final mid = engine.snapToRoute(engine.positionAtDistance(600));
        final midSeg = engine.snappedSegmentIndex;
        expect(midSeg, greaterThan(40));
        expect(midSeg, lessThan(70));
        // The drawn route start must stay on the road line.
        expect(mid.latitude, closeTo(10.8231, 1e-6));
        // Further on, more of the route has been consumed.
        engine.snapToRoute(engine.positionAtDistance(900));
        expect(engine.snappedSegmentIndex, greaterThan(midSeg));
      },
    );

    test('route consumption is monotonic even with noisy GPS fixes', () {
      final engine = TurnByTurnEngine(_straightRoute());
      var prev = 0;
      // Drive along with random ±20 m noise; the consumed index must never
      // go backward (otherwise the drawn route would visibly grow back).
      for (var d = 0.0; d < 1000; d += 25) {
        final on = engine.positionAtDistance(d);
        final noisy = LatLng(
          on.latitude + (d * 0.000031) % 0.00018 - 0.00009, // ±10 m lat wobble
          on.longitude + 0.00005, // fixed +5 m lng offset
        );
        engine.snapToRoute(noisy);
        expect(
          engine.snappedSegmentIndex,
          greaterThanOrEqualTo(prev),
          reason: 'consumed start must never move backward (at ${d}m)',
        );
        prev = engine.snappedSegmentIndex;
      }
    });

    test('lateralOffset moves a point perpendicular to the route', () {
      final engine = TurnByTurnEngine(_straightRoute());
      final on = engine.positionAtDistance(300);
      // The straight test route is EASTBOUND (lat constant); the right-hand
      // side of an eastbound road points south (bearing 90° + 90° = 180°).
      final side = engine.lateralOffset(on, 10);
      expect(side.latitude, lessThan(on.latitude)); // south = smaller latitude
      // ~10 m away from the route.
      expect(distanceMeters(on, side), closeTo(10, 1.5));
      // And snapping the offset point pulls it straight back onto the route.
      final back = engine.snapToRoute(side);
      expect(distanceMeters(back, on), lessThan(3));
    });

    test('routeBearing points along the road ahead (eastbound)', () {
      final engine = TurnByTurnEngine(_straightRoute());
      // Anywhere along the straight eastbound road the ahead-bearing is 90°.
      for (final d in [100.0, 400.0, 700.0]) {
        engine.snapToRoute(engine.positionAtDistance(d));
        engine.update(engine.positionAtDistance(d));
        expect(engine.routeBearing(), closeTo(90, 6));
      }
    });

    test('routeBearing is stable under repeated noisy fixes', () {
      final engine = TurnByTurnEngine(_straightRoute());
      var prev = -1.0;
      // Repeated calls must not make the bearing jump around (the old
      // nearest-segment scan flipped between segments at vertices).
      for (var d = 0.0; d < 900; d += 25) {
        final on = engine.positionAtDistance(d);
        final noisy = LatLng(
          on.latitude + (d * 0.000031) % 0.00018 - 0.00009,
          on.longitude + 0.00005,
        );
        engine.snapToRoute(noisy);
        engine.update(noisy);
        final b = engine.routeBearing();
        expect(b, closeTo(90, 12)); // always ~east, never flipping to west
        if (prev >= 0) {
          expect((b - prev).abs(), lessThan(6)); // no per-fix jumps
        }
        prev = b;
      }
    });

    test('routeBearing follows the road through a bend', () {
      // East then south.
      final geometry = [
        const LatLng(10.82, 106.62),
        const LatLng(10.82, 106.64),
        const LatLng(10.80, 106.64),
      ];
      final engine = TurnByTurnEngine(
        OsrmRoute(
          distance: 5000,
          duration: 400,
          geometry: geometry,
          steps: const [],
        ),
      );
      // On the east-west leg → east (≈90°).
      engine.snapToRoute(const LatLng(10.82, 106.63));
      expect(engine.routeBearing(), closeTo(90, 10));
      // Southbound straight road → south (≈180°).
      final south = TurnByTurnEngine(
        OsrmRoute(
          distance: 2500,
          duration: 200,
          geometry: [const LatLng(10.82, 106.64), const LatLng(10.80, 106.64)],
          steps: const [],
        ),
      );
      south.snapToRoute(const LatLng(10.81, 106.6401));
      expect(south.routeBearing(), closeTo(180, 10));
    });
  });
}
