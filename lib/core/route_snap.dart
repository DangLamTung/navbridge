/// Project a point onto a route polyline so the car arrow + camera always
/// ride the road. The Kalman smoothing/glide can cut across a corner between
/// GPS fixes; this glues the drawn position back onto the route, Google-Maps
/// style. Only snaps when the point is near the route (≤ [maxDistanceM]) — a
/// genuine off-route deviation stays free so the puck shows the real position.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Returns the nearest point on [polyline] to [p] if that distance is
/// ≤ [maxDistanceM], otherwise [p] unchanged.
///
/// Projection runs in a flat local east/north metre frame around [p] (the
/// same scaling used by the nav engine) so distances are real metres and the
/// `t` interpolation is clean; the result is converted back to lat/lng.
LatLng snapToRoutePolyline(
  LatLng p,
  List<LatLng> polyline, {
  double maxDistanceM = 40.0,
}) {
  if (polyline.length < 2) return p;
  final mPerDegLat = 111320.0;
  final mPerDegLng = mPerDegLat * math.cos(p.latitude * math.pi / 180);
  var bestD = double.infinity;
  var best = p;
  for (var i = 0; i < polyline.length - 1; i++) {
    final a = polyline[i], b = polyline[i + 1];
    // Segment endpoints in metres around p.
    final ax = (a.longitude - p.longitude) * mPerDegLng;
    final ay = (a.latitude - p.latitude) * mPerDegLat;
    final bx = (b.longitude - p.longitude) * mPerDegLng;
    final by = (b.latitude - p.latitude) * mPerDegLat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 < 1e-12 ? 0.0 : ((0 - ax) * dx + (0 - ay) * dy) / len2;
    final tt = t.clamp(0.0, 1.0).toDouble();
    final px = ax + tt * dx, py = ay + tt * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < bestD) {
      bestD = d;
      best = LatLng(
        p.latitude + py / mPerDegLat,
        p.longitude + px / mPerDegLng,
      );
    }
  }
  return bestD <= maxDistanceM ? best : p;
}
