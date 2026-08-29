/// Shared polyline geometry for the offline nav-data services
/// (`offline_cameras.dart`, `offline_road_signs.dart`, …).
///
/// These were previously copy-pasted as private helpers in each service
/// (see git history / the nav-signs work). They are pure, top-level and
/// isolate-safe, so they run unchanged inside the `compute(...)` workers that
/// the services use to keep the per-second nav checks off the UI thread.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Sample budget for [withinCoarseCorridor]'s decimation.
const int kCoarseTarget = 256;

/// Cheap equirectangular metres between two points — ~4-5x faster than
/// haversine (one `cos` + one `sqrt` vs haversine's four trig + asin). Plenty
/// for cumulative/decimation math where a few % of error is invisible; NOT for
/// precise small-distance work (use `Distance` there).
double fastDistanceMeters(LatLng a, LatLng b) {
  final lat = (a.latitude + b.latitude) * math.pi / 360.0;
  final dx = (b.longitude - a.longitude) * 111320.0 * math.cos(lat);
  final dy = (b.latitude - a.latitude) * 110540.0;
  return math.sqrt(dx * dx + dy * dy);
}

/// Reduce [points] for DISPLAY (map rendering), not for nav math. Long routes
/// (thousands of dense OSRM vertices) render identically at road scale with
/// far fewer vertices, so the map stays responsive right after routing a long
/// distance. Keeps ~1 vertex per [spacingM] metres, then caps at [maxPoints].
List<LatLng> decimatePolyline(
  List<LatLng> points, {
  double spacingM = 20,
  int maxPoints = 6000,
}) {
  if (points.length <= maxPoints) return points;
  final out = <LatLng>[points.first];
  var last = points.first;
  var since = 0.0;
  for (var i = 1; i < points.length - 1; i++) {
    since += fastDistanceMeters(last, points[i]);
    if (since >= spacingM) {
      out.add(points[i]);
      last = points[i];
      since = 0.0;
    }
  }
  out.add(points.last);
  if (out.length > maxPoints) {
    final step = (out.length / maxPoints).ceil();
    return <LatLng>[
      for (var i = 0; i < out.length; i += step) out[i],
      out.last,
    ];
  }
  return out;
}

/// Cheap test: is [p] within roughly [corridorMeters] of the polyline,
/// using a decimated polyline + a straight-line distance check? Returns
/// false for objects clearly far from the road, so the expensive exact
/// projection in [nearestAlong] only runs for the few candidates that might
/// actually be on/near the route.
///
/// Decimation is ADAPTIVE: long polylines (e.g. a 191 km route with tens of
/// thousands of vertices) are sampled down to ~[kCoarseTarget] vertices so
/// the check stays O(samples) per object, while short routes check every
/// vertex (no decimation) so an object mid-route is never missed.
///
/// Deliberately LOOSE (corridor × 3) so it never rejects an object the exact
/// scan would accept.
bool withinCoarseCorridor(List<LatLng> geo, LatLng p, double corridorMeters) {
  if (geo.isEmpty) return false;
  final step = math.max(1, (geo.length / kCoarseTarget).ceil());
  var best = double.infinity;
  for (var i = 0; i < geo.length; i += step) {
    final d = const Distance().as(LengthUnit.Meter, geo[i], p);
    if (d < best) best = d;
    if (best <= corridorMeters * 3) return true; // close enough — early out
  }
  return best <= corridorMeters * 3;
}

/// Metres from [from] (projected onto [geo]) to [target] (projected onto
/// [geo]), along the polyline. Returns null if either point is beyond the
/// polyline's ends.
double? routeMetersAhead(LatLng from, LatLng target, List<LatLng> geo) {
  // Find along-route distance (from start) of the nearest points.
  final f = nearestAlong(geo, from);
  final t = nearestAlong(geo, target);
  if (f == null || t == null) return null;
  return t - f;
}

/// Cumulative distance from the polyline start to the nearest point on it to
/// [p]. Returns null if [p] is farther than 200 m from the polyline (i.e. not
/// on the route — e.g. an object on a parallel street).
double? nearestAlong(List<LatLng> geo, LatLng p) {
  const Distance d = Distance();
  double bestDist = double.infinity;
  double bestCum = 0;
  double cum = 0;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final seg = d.as(LengthUnit.Meter, a, b);
    // Project p onto segment a-b (linear approx at city scale).
    final proj = projectOnSegment(a, b, p);
    final off = d.as(LengthUnit.Meter, proj, p);
    if (off < bestDist) {
      bestDist = off;
      bestCum = cum + d.as(LengthUnit.Meter, a, proj);
    }
    cum += seg;
  }
  // Too far from the route → not on it (parallel street / unrelated).
  if (bestDist > 200) return null;
  return bestCum;
}

/// Point on segment a→b nearest to [p] (planar projection, fine at city
/// scale). Clamped to the segment; returns [a] for a zero-length segment.
LatLng projectOnSegment(LatLng a, LatLng b, LatLng p) {
  final ax = a.longitude, ay = a.latitude;
  final bx = b.longitude, by = b.latitude;
  final px = p.longitude, py = p.latitude;
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return a;
  var t = ((px - ax) * dx + (py - ay) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  return LatLng(ay + t * dy, ax + t * dx);
}
