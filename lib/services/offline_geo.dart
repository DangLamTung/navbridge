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
