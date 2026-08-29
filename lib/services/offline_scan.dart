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
List<(int, double)> pointsAheadOnRoute<T extends OfflinePoint>(
  (LatLng, List<LatLng>, List<T>, double) args,
) {
  final (current, geometry, items, maxAheadMeters) = args;
  if (geometry.length < 2 || items.isEmpty) return const [];
  const Distance d = Distance();
  final out = <(int, double)>[];
  for (var i = 0; i < items.length; i++) {
    final p = items[i].pos;
    // Quick reject: straight-line farther than max ahead → can't be ahead.
    if (d.as(LengthUnit.Meter, current, p) > maxAheadMeters + 500) continue;
    final m = routeMetersAhead(current, p, geometry);
    if (m != null && m >= 0 && m <= maxAheadMeters) {
      out.add((i, m));
    }
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
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
