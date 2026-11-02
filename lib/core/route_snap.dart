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
  final best = _nearestInRange(p, polyline, 0, polyline.length - 1);
  return best.distanceM <= maxDistanceM ? best.point : p;
}

/// Distance from [p] to the nearest point of [polyline] (metres), plus that
/// point. Unlike [snapToRoutePolyline] the distance is always real — no
/// `maxDistanceM` clamp — so a caller that wants to *filter* by distance
/// (the camera route-corridor test) gets the truth instead of 0.
({LatLng point, double distanceM}) nearestOnRoute(
  LatLng p,
  List<LatLng> polyline,
) {
  if (polyline.length < 2) return (point: p, distanceM: double.infinity);
  final best = _nearestInRange(p, polyline, 0, polyline.length - 1);
  return (point: best.point, distanceM: best.distanceM);
}

/// Spatial index over one route polyline.
///
/// The car puck re-snaps **~30 times a second** and the camera layer re-tests
/// every camera on **every GPS fix**; both used to scan the whole route each
/// time. Measured on a 30,000-point route (a ~400 km trip) that is ~0.5 ms per
/// snap, i.e. ~15 ms every second of pure re-snapping, and a ~100 ms burst for
/// the camera pass — the "laggy now and then" on long routes.
///
/// Segments are bucketed into ~[cellM] metre cells; a query only looks at the
/// nine cells around the point. Results are identical to the full scan: the
/// searched square always covers at least `radius * cellM` metres, and
/// [nearest] falls back to a full scan for the (rare) long segments that do
/// not fit a bounded cell run.
class RouteSnapIndex {
  RouteSnapIndex(this.polyline, {this.cellM = 200.0}) {
    if (polyline.length < 2) return;
    var latSum = 0.0;
    for (final p in polyline) {
      latSum += p.latitude;
    }
    final meanLat = latSum / polyline.length;
    _cellLat = cellM / 111320.0;
    _cellLng = cellM / (111320.0 * math.cos(meanLat * math.pi / 180));
    for (var i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i], b = polyline[i + 1];
      final cx0 = _cellX(math.min(a.longitude, b.longitude));
      final cx1 = _cellX(math.max(a.longitude, b.longitude));
      final cy0 = _cellY(math.min(a.latitude, b.latitude));
      final cy1 = _cellY(math.max(a.latitude, b.latitude));
      if ((cx1 - cx0 + 1) * (cy1 - cy0 + 1) > 1024) {
        // A segment that long is not a road vertex pair we can bucket cheaply
        // (typically a coordinate mistake): keep it for the full-scan path.
        _oversized.add(i);
        continue;
      }
      for (var cx = cx0; cx <= cx1; cx++) {
        for (var cy = cy0; cy <= cy1; cy++) {
          (_cells[_key(cx, cy)] ??= <int>[]).add(i);
        }
      }
    }
  }

  final List<LatLng> polyline;
  final double cellM;
  late final double _cellLat;
  late final double _cellLng;
  final Map<int, List<int>> _cells = {};
  final List<int> _oversized = [];

  int _cellX(double lon) => (lon / _cellLng).floor();
  int _cellY(double lat) => (lat / _cellLat).floor();

  // Cell coordinates can be negative; keep the hash collision-free.
  int _key(int cx, int cy) => (cx + 100000) * 200003 + (cy + 100000);

  /// Nearest point on the route to [p]. [maxDistanceM] clamps the result the
  /// same way [snapToRoutePolyline] does (the input point is returned when the
  /// route is farther away).
  ({LatLng point, double distanceM}) nearest(
    LatLng p, {
    double maxDistanceM = 40.0,
  }) {
    if (polyline.length < 2) return (point: p, distanceM: double.infinity);
    // A corridor wider than the searched cells means "give me the true
    // distance" — scan once instead of sweeping a huge cell radius (asking for
    // 1e9 m used to start a 5-million-cell loop).
    if (!maxDistanceM.isFinite || maxDistanceM > cellM * 3) {
      final exact = _nearestInRange(p, polyline, 0, polyline.length - 1);
      return exact.distanceM > maxDistanceM
          ? (point: p, distanceM: exact.distanceM)
          : exact;
    }
    final radius = math.max(1, (maxDistanceM / cellM).ceil());
    final cx = _cellX(p.longitude);
    final cy = _cellY(p.latitude);
    var best = _nearestInCells(p, cx, cy, radius);
    if (best.distanceM > maxDistanceM && _oversized.isNotEmpty) {
      for (final i in _oversized) {
        final c = _segmentDistance(p, polyline[i], polyline[i + 1]);
        if (c.distanceM < best.distanceM) best = c;
      }
    }
    // The searched square covers at least radius*cellM metres; if nothing was
    // found inside it the route really is farther than that, so clamping is
    // correct without a full rescan.
    if (best.distanceM > maxDistanceM) {
      return (point: p, distanceM: best.distanceM);
    }
    return best;
  }

  ({LatLng point, double distanceM}) _nearestInCells(
    LatLng p,
    int cx,
    int cy,
    int radius,
  ) {
    var bestD = double.infinity;
    var bestP = p;
    final seen = <int>{};
    for (var dx = -radius; dx <= radius; dx++) {
      for (var dy = -radius; dy <= radius; dy++) {
        final idx = _cells[_key(cx + dx, cy + dy)];
        if (idx == null) continue;
        for (final i in idx) {
          if (!seen.add(i)) continue;
          final c = _segmentDistance(p, polyline[i], polyline[i + 1]);
          if (c.distanceM < bestD) {
            bestD = c.distanceM;
            bestP = c.point;
          }
        }
      }
    }
    return (point: bestP, distanceM: bestD);
  }
}

/// Closest point on segments [from]..[to] (inclusive) — the shared maths of the
/// full scan and the index, so both return the same numbers.
({LatLng point, double distanceM}) _nearestInRange(
  LatLng p,
  List<LatLng> polyline,
  int from,
  int to,
) {
  var bestD = double.infinity;
  var bestP = p;
  for (var i = from; i < to; i++) {
    final c = _segmentDistance(p, polyline[i], polyline[i + 1]);
    if (c.distanceM < bestD) {
      bestD = c.distanceM;
      bestP = c.point;
    }
  }
  return (point: bestP, distanceM: bestD);
}

({LatLng point, double distanceM}) _segmentDistance(
  LatLng p,
  LatLng a,
  LatLng b,
) {
  const mPerDegLat = 111320.0;
  final mPerDegLng = mPerDegLat * math.cos(p.latitude * math.pi / 180);
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
  return (
    point: LatLng(p.latitude + py / mPerDegLat, p.longitude + px / mPerDegLng),
    distanceM: d,
  );
}
