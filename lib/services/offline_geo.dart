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

/// Metres per degree of latitude (equirectangular sphere, ±0.3 % over Việt Nam).
const double kMetersPerDegLat = 111320.0;

/// Metres per degree of longitude at [latDeg] — shrinks towards the poles.
double metersPerDegLng(double latDeg) =>
    kMetersPerDegLat * math.cos(latDeg * math.pi / 180.0);

/// Signed metres of [p] along compass [headingDeg] from [from]: positive = in
/// front of the heading, negative = behind. Used to drop markers the driver has
/// already passed.
double alongHeadingMeters(LatLng from, LatLng p, double headingDeg) {
  final rad = headingDeg * math.pi / 180.0;
  final dy = (p.latitude - from.latitude) * kMetersPerDegLat;
  final dx = (p.longitude - from.longitude) * metersPerDegLng(from.latitude);
  return dx * math.sin(rad) + dy * math.cos(rad);
}

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
  if (geo.length == 1) {
    return fastDistanceMeters(geo.first, p) <= corridorMeters * 3;
  }
  final step = math.max(1, (geo.length / kCoarseTarget).ceil());
  final thresh = corridorMeters * 3;
  for (var i = 0; i < geo.length - 1; i += step) {
    final j = math.min(i + step, geo.length - 1);
    final proj = projectOnSegment(geo[i], geo[j], p);
    if (fastDistanceMeters(proj, p) <= thresh) {
      return true; // close enough — early out
    }
  }
  return false;
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

/// Compass bearing (°, 0 = north, clockwise) of the polyline [geo] at the point
/// nearest to [p] — the direction the DRIVER is travelling there, not the
/// phone's heading and not the polyline's end-to-end direction.
///
/// This is the reference a sign's own `heading` is compared against: a plate
/// faces the traffic it governs, so the same boundary has one plate facing each
/// way. Returns null when [p] is not on the polyline (> 200 m) or the nearest
/// segment has no length.
double? routeBearingAt(List<LatLng> geo, LatLng p) {
  var best = double.infinity;
  var bearing = 0.0;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final proj = projectOnSegment(a, b, p);
    final off = fastDistanceMeters(proj, p);
    if (off >= best) continue;
    final dx = (b.longitude - a.longitude) * metersPerDegLng(a.latitude);
    final dy = (b.latitude - a.latitude) * kMetersPerDegLat;
    if (dx == 0 && dy == 0) continue; // zero-length segment: no direction
    best = off;
    bearing = (math.atan2(dx, dy) * 180.0 / math.pi + 360.0) % 360.0;
  }
  if (best > 200) return null;
  return bearing;
}

/// True when a plate whose own `heading` is [signHeading] governs the traffic
/// travelling on bearing [travelBearing], within [toleranceDeg].
///
/// A plate faces the traffic it applies to (QCVN 41:2019), so on a divided road
/// the two directions' plates face opposite ways. [toleranceDeg] 60° keeps a
/// plate that is a little askew while rejecting the opposite carriageway's.
bool signFacesTravel({
  required double signHeading,
  required double travelBearing,
  double toleranceDeg = 60.0,
}) {
  var d = (signHeading - travelBearing) % 360.0;
  if (d < 0) d += 360.0;
  if (d > 180.0) d = 360.0 - d;
  return d <= toleranceDeg;
}

/// Perpendicular distance (m) from [p] to the polyline [geo] — how far OFF the
/// route a point sits, as opposed to how far along it.
///
/// A sign is a sign OF the road it stands on: one 150 m to the side belongs to a
/// crossing or parallel street, and announcing it as "ahead on the route" is the
/// misfire the driver reported (2026-09-24: "for sign outside the segment we can
/// reduce"). [nearestAlong] knows this distance already but only uses it as a
/// 200 m cutoff; this exposes it so callers can apply their own.
///
/// Returns null when [p] is farther than 200 m from [geo] (not this route at
/// all).
double? lateralOffsetMeters(List<LatLng> geo, LatLng p) =>
    signedLateralOffsetMeters(geo, p)?.abs();

/// Signed perpendicular offset (m) from the polyline [geo] to [p]: POSITIVE
/// when [p] stands to the RIGHT of the direction of travel, NEGATIVE when it
/// stands to the LEFT, `0` when it sits on the centreline.
///
/// A biển báo hiệu is erected on the RIGHT-hand verge for the traffic it
/// governs (QCVN 41:2019 — "đặt về phía tay phải theo chiều đi"); the same sign
/// on the LEFT belongs to the opposite carriageway. [lateralOffsetMeters]
/// throws the sign away, so the ahead scan could not tell our post from the
/// other direction's, and the driver heard (and adopted as the limit) BOTH
/// numbers — the 50/60 that swap on every divided road (user, 2026-10-24:
/// "biển nào m cũng đọc như con vẹt óc lợn, trong khi biển có hiệu lực cần đọc
/// là biển bên tay phải").
///
/// Returns null when [p] is farther than 200 m from [geo] (not this route at
/// all). The magnitude is the same perpendicular distance
/// [lateralOffsetMeters] reports.
double? signedLateralOffsetMeters(List<LatLng> geo, LatLng p) {
  var best = double.infinity;
  var rightOfTravel = true;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final proj = projectOnSegment(a, b, p);
    final off = fastDistanceMeters(proj, p);
    if (off >= best) continue;
    best = off;
    // Local planar frame (x = east, y = north). The cross product of the
    // segment direction with the projection→point vector is POSITIVE on the
    // right-hand side of travel: heading north + point east ⇒ +, heading east
    // + point south ⇒ +, and so on.
    final segX = (b.longitude - a.longitude) * metersPerDegLng(a.latitude);
    final segY = (b.latitude - a.latitude) * kMetersPerDegLat;
    final toX = (p.longitude - proj.longitude) * metersPerDegLng(a.latitude);
    final toY = (p.latitude - proj.latitude) * kMetersPerDegLat;
    rightOfTravel = segY * toX - segX * toY >= 0;
  }
  if (best > 200) return null;
  if (best == 0) return 0; // on the centreline — the side is not recorded
  return rightOfTravel ? best : -best;
}

/// Cumulative distance from the polyline start to the nearest point on it to
/// [p]. Returns null if [p] is farther than 200 m from the polyline (i.e. not
/// on the route — e.g. an object on a parallel street).
double? nearestAlong(List<LatLng> geo, LatLng p) {
  double bestDist = double.infinity;
  double bestCum = 0;
  double cum = 0;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final seg = fastDistanceMeters(a, b);
    // Project p onto segment a-b (linear approx at city scale).
    final proj = projectOnSegment(a, b, p);
    final off = fastDistanceMeters(proj, p);
    if (off < bestDist) {
      bestDist = off;
      bestCum = cum + fastDistanceMeters(a, proj);
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

/// The point [aheadM] metres PAST [from] along [geo] — for a maneuver at [from]
/// this is the road on the FAR side of the turn, which is a different street with
/// its own limit.
///
/// Used by the voice callout: "rẽ trái vào X, tốc độ tối đa …" must quote X, not
/// the street the car is still on. Samples the polyline the route engine produced
/// (so it cannot drift onto a parallel street the way a free-floating probe
/// could), and returns [geo.last] when the route ends before [aheadM].
LatLng? pointPast(LatLng from, List<LatLng> geo, double aheadM) {
  if (geo.length < 2) return null;
  final at = nearestAlong(geo, from);
  if (at == null) return null;
  const Distance d = Distance();
  var acc = 0.0;
  for (var i = 0; i + 1 < geo.length; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final seg = d.as(LengthUnit.Meter, a, b);
    if (acc + seg >= at + aheadM) {
      final t = seg <= 0 ? 0.0 : ((at + aheadM) - acc) / seg;
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    }
    acc += seg;
  }
  return geo.last;
}
