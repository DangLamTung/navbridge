/// Tests for `snapToRoutePolyline` — gluing the car arrow to the route so
/// Kalman smoothing/gliding never drifts the puck off the road at corners.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_snap.dart';

final double _mPerDegLat = 111320.0;
final double _mPerDegLng = 111320.0 * math.cos(10.8 * math.pi / 180);

double _degLat(double m) => m / _mPerDegLat;
double _degLng(double m) => m / _mPerDegLng;

double _dist(LatLng a, LatLng b) {
  final dLat = (a.latitude - b.latitude) * _mPerDegLat;
  final dLng = (a.longitude - b.longitude) * _mPerDegLng;
  return math.sqrt(dLat * dLat + dLng * dLng);
}

void main() {
  // A simple east-then-north route (a 90° corner) around (10.8, 106.65).
  final corner = LatLng(10.8, 106.65);
  final route = <LatLng>[
    LatLng(corner.latitude, corner.longitude), // start
    LatLng(corner.latitude, corner.longitude + _degLng(100)), // east
    LatLng(corner.latitude + _degLat(100), corner.longitude + _degLng(100)),
  ];

  test('snaps a point slightly off a straight segment onto the road', () {
    // The Kalman glide ran ~6 m north of the east-bound segment.
    final off = LatLng(
      corner.latitude + _degLat(6),
      corner.longitude + _degLng(50),
    );
    final snapped = snapToRoutePolyline(off, route);
    // Back on the road (the east segment, same latitude as the route).
    expect((snapped.latitude - corner.latitude) * _mPerDegLat, lessThan(0.5));
    expect(_dist(snapped, off), lessThan(7));
  });

  test('pulls a corner-cutting glide back onto the path (the bug)', () {
    // The car cut diagonally across the 90° corner (inside the bend).
    final cut = LatLng(
      corner.latitude + _degLat(35),
      corner.longitude + _degLng(65),
    );
    final snapped = snapToRoutePolyline(cut, route);
    // The snapped point must lie ON one of the two route segments.
    final onEast =
        (snapped.latitude - corner.latitude).abs() * _mPerDegLat < 0.5;
    final onNorth =
        (snapped.longitude - (corner.longitude + _degLng(100))).abs() *
            _mPerDegLng <
        0.5;
    expect(onEast || onNorth, isTrue, reason: 'snapped off the road');
    // And the corner cut is gone: it moved back to the road.
    expect(_dist(snapped, cut), greaterThan(10));
  });

  test('leaves a genuinely off-route point alone (>40 m)', () {
    final far = LatLng(corner.latitude + _degLat(120), corner.longitude);
    final snapped = snapToRoutePolyline(far, route);
    expect(snapped.latitude, far.latitude);
    expect(snapped.longitude, far.longitude);
  });

  test('clamps the projection to segment endpoints', () {
    // Point 30 m past the end of the route (within the 40 m snap window) →
    // snaps onto the last vertex, not beyond it.
    final beyond = LatLng(
      corner.latitude + _degLat(130),
      corner.longitude + _degLng(100),
    );
    final snapped = snapToRoutePolyline(beyond, route);
    final last = route.last;
    expect(_dist(snapped, last), lessThan(1.0));
  });

  test('returns the point unchanged for a degenerate polyline', () {
    final p = LatLng(10.8, 106.65);
    expect(snapToRoutePolyline(p, const <LatLng>[]), same(p));
    expect(snapToRoutePolyline(p, [p]), same(p));
  });
}
