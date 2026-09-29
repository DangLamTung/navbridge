/// Shared offline "points ahead of / near a route" scanners for the point
/// layers (`offline_cameras.dart`, `offline_road_signs.dart`).
///
/// Both layers used to run the SAME two isolate workers with only the item
/// type changed. This module hoists them onto a common [OfflinePoint]
/// interface so the route projection, bbox/coarse filters and ordering live
/// in exactly one place. The workers stay top-level and isolate-safe — call
/// them via `compute(...)` from the UI isolate.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'offline_geo.dart';

/// Any offline layer item that can be projected onto a route polyline.
abstract interface class OfflinePoint {
  LatLng get pos;
}

/// Indices of [items] AHEAD of [current] along [geometry], ordered by
/// along-route distance, limited to [maxAheadMeters]. Isolate-safe.
///
/// Takes a single record so it can be passed straight to `compute(...)`.
///
/// ONLY the stretch of [geometry] the question can involve is scanned: an item
/// that is [maxAheadMeters] ahead of the car cannot be found by looking at the
/// polyline a thousand kilometres away, yet the projection helpers walk the
/// WHOLE list per item. On the 1 690 km QL1A route (84 532 vertices) that made
/// one query take 18 s on the web — where `compute()` runs on the same thread —
/// and the nav loop never caught up with the drive. The window is derived once
/// (a coarse nearest-vertex scan + a walk of ~[maxAheadMeters] ahead of it),
/// then every item is projected against it; distances stay exact because both
/// [current] and the item lie inside the same window.
List<(int, double)> pointsAheadOnRoute<T extends OfflinePoint>(
  (LatLng, List<LatLng>, List<T>, double, double) args, {
  /// Per-item override of the lateral limit. A zone-referenced sign is stored
  /// at an area vertex rather than on the carriageway, so it needs a wider
  /// corridor than a roadside post — see [kZoneLateralMeters].
  double Function(T item)? lateralFor,
}) {
  final (current, geometry, items, maxAheadMeters, lateralMeters) = args;
  if (geometry.length < 2 || items.isEmpty) return const [];
  final window = _aheadWindow(geometry, current, maxAheadMeters);
  if (window.length < 2) return const [];
  const Distance d = Distance();
  final out = <(int, double)>[];
  for (var i = 0; i < items.length; i++) {
    final p = items[i].pos;
    // Quick reject: straight-line farther than max ahead → can't be ahead.
    if (d.as(LengthUnit.Meter, current, p) > maxAheadMeters + 500) continue;
    // A point to the SIDE of the route belongs to the street it stands on (a
    // crossing / parallel road), so it is not "ahead on this route" — see
    // [lateralOffsetMeters]. Callers pass 0 to keep the old behaviour.
    final limit = lateralFor?.call(items[i]) ?? lateralMeters;
    if (limit > 0) {
      final off = lateralOffsetMeters(window, p);
      if (off == null || off > limit) continue;
    }
    final m = routeMetersAhead(current, p, window);
    if (m != null && m >= 0 && m <= maxAheadMeters) {
      out.add((i, m));
    }
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

/// The slice of [geometry] that can hold a point within [maxAheadMeters] AHEAD
/// of [current]: a short lead-in behind the car (a fix that lands just past a
/// vertex still projects onto the right segment) plus the way forward until the
/// budget is spent.
///
/// The nearest vertex is found by a COARSE scan (≤ ~512 samples of the cheap
/// equirectangular distance) refined over one coarse step — accurate to a few
/// vertices, which is all a window needs (see [pointsAheadOnRoute]).
List<LatLng> _aheadWindow(
  List<LatLng> geometry,
  LatLng current,
  double maxAheadMeters,
) {
  final n = geometry.length;
  if (n < 3) return geometry;
  final step = math.max(1, (n / 512).ceil());
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < n; i += step) {
    final d = fastDistanceMeters(geometry[i], current);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  final hiRef = math.min(n - 1, best + step);
  for (var i = math.max(0, best - step); i <= hiRef; i++) {
    final d = fastDistanceMeters(geometry[i], current);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  var lo = best;
  var back = 0.0;
  while (lo > 0 && back < 200) {
    back += fastDistanceMeters(geometry[lo - 1], geometry[lo]);
    lo--;
  }
  var hi = best;
  var ahead = 0.0;
  while (hi < n - 1 && ahead < maxAheadMeters + 40) {
    ahead += fastDistanceMeters(geometry[hi], geometry[hi + 1]);
    hi++;
  }
  return geometry.sublist(lo, hi + 1);
}

/// Indices of [items] within ~[corridorMeters] of [geometry] — the map-layer
/// filter (NOT every item nationwide, only those on/near the route).
/// Isolate-safe.
///
/// Two cheap pre-filters keep the O(polyline) exact scan tiny:
///   1. Bounding box: an item outside the route's padded box is skipped.
///   2. Coarse corridor: straight-line distance to a DECIMATED polyline with
///      a LOOSE threshold — rejects items inside the bbox but far from the
///      road, so `nearestAlong` (the expensive exact scan) only runs for the
///      few survivors.
List<int> pointsNearRoute<T extends OfflinePoint>(
  (List<LatLng>, List<T>, double) args,
) {
  final (geometry, items, corridorMeters) = args;
  if (geometry.length < 2 || items.isEmpty) return const [];
  // Bounding box of the route + corridor padding.
  var minLat = geometry.first.latitude;
  var maxLat = geometry.first.latitude;
  var minLng = geometry.first.longitude;
  var maxLng = geometry.first.longitude;
  for (final p in geometry) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLng) minLng = p.longitude;
    if (p.longitude > maxLng) maxLng = p.longitude;
  }
  // Convert the corridor to degrees (lat ~111 km/°, lng shrinks with cos lat).
  final latPad = corridorMeters / 111320.0;
  final lngPad =
      corridorMeters /
      (111320.0 * math.cos(((minLat + maxLat) / 2.0) * math.pi / 180.0));
  final loLat = minLat - latPad;
  final hiLat = maxLat + latPad;
  final loLng = minLng - lngPad;
  final hiLng = maxLng + lngPad;

  final out = <int>[];
  for (var i = 0; i < items.length; i++) {
    final p = items[i].pos;
    if (p.latitude < loLat ||
        p.latitude > hiLat ||
        p.longitude < loLng ||
        p.longitude > hiLng) {
      continue; // outside the route's padded bounding box — cannot be near it
    }
    // Coarse pre-filter (see doc above).
    if (!withinCoarseCorridor(geometry, p, corridorMeters)) continue;
    // `nearestAlong` returns null when the item is >200 m from the polyline
    // (i.e. on a parallel/adjacent street) — exactly the corridor filter we
    // want.
    if (nearestAlong(geometry, p) != null) {
      out.add(i);
    }
  }
  return out;
}
