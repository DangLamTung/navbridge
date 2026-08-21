/// Offline speed/red-light camera index for Việt Nam — bundled as a compact
/// JSON (`assets/offline_map/vietnam_cameras.json`) generated from provincial
/// police "phạt nguội" (fine) lists + OSM Overpass.
///
/// Works with NO network (like `offline_poi.dart`). During navigation the app
/// finds the nearest camera AHEAD on the route and warns the driver
/// (voice + notification + PiP + ESP) when within a trigger distance.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// One offline camera / traffic-sign point.
class OfflineCamera {
  final String name;
  final double lat;
  final double lng;

  /// `speed` | `red_light` | `violations` | `sign` — the alert focus.
  final String focus;

  /// Optional road-sign label (Waze tiles): no_passing, no_left_turn,
  /// residential_start, end_of_prohibitions, …
  final String? sign;

  /// Posted speed limit at this point, km/h (Waze speed cameras/signs).
  final int? speedLimit;

  /// Optional count of devices at the point (police lists).
  final int? devices;

  /// Optional district / province label.
  final String? district;

  const OfflineCamera({
    required this.name,
    required this.lat,
    required this.lng,
    required this.focus,
    this.sign,
    this.speedLimit,
    this.devices,
    this.district,
  });

  LatLng get pos => LatLng(lat, lng);

  /// Distance in metres from [p] to this camera.
  double distanceM(LatLng p) => const Distance().as(LengthUnit.Meter, p, pos);

  factory OfflineCamera.fromJson(Map<String, dynamic> j) => OfflineCamera(
    name: (j['name'] ?? '') as String,
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
    focus: (j['focus'] ?? 'violations') as String,
    sign: j['sign'] as String?,
    speedLimit: (j['speed_limit'] as num?)?.toInt(),
    devices: (j['devices'] as num?)?.toInt(),
    district: j['district'] as String?,
  );
}

/// A camera that is AHEAD of the driver on the route.
class CameraAhead {
  final OfflineCamera camera;

  /// Distance along the route (not straight-line) from the car, metres.
  final double routeMeters;

  const CameraAhead({required this.camera, required this.routeMeters});
}

List<OfflineCamera>? _cameras;
bool _loaded = false;
Future<List<OfflineCamera>>? _loading;

/// Load the bundled camera index once (idempotent, cached).
Future<List<OfflineCamera>> loadOfflineCameras() {
  if (_cameras != null) return Future.value(_cameras!);
  if (_loading != null) return _loading!;
  final fut = _doLoad();
  _loading = fut;
  return fut;
}

Future<List<OfflineCamera>> _doLoad() async {
  if (_loaded && _cameras != null) return _cameras!;
  _loaded = true;
  try {
    final raw = await rootBundle.loadString(
      'assets/offline_map/vietnam_cameras.json',
    );
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _cameras = [
      for (final it
          in (data['cameras'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
        OfflineCamera.fromJson(it),
    ];
  } catch (_) {
    _cameras = const [];
  }
  return _cameras!;
}

/// Find cameras AHEAD of [current] along [geometry], ordered by distance along
/// the route. Only returns cameras within [maxAheadMeters] ahead.
///
/// Approach: walk the route polyline from the point nearest to [current];
/// for each camera, project it onto the polyline (nearest point) and compute
/// the along-route distance. Cameras behind the car are skipped.
///
/// Runs in a BACKGROUND ISOLATE so the per-second nav check never blocks the
/// UI thread on a long route.
Future<List<CameraAhead>> camerasAheadOnRoute(
  LatLng current,
  List<LatLng> geometry, {
  double maxAheadMeters = 1500,
}) async {
  final cams = await loadOfflineCameras();
  if (cams.isEmpty || geometry.length < 2) return const [];
  final res = await compute(_camerasAheadOnRoute, (
    current,
    geometry,
    cams,
    maxAheadMeters,
  ));
  return [
    for (final (i, m) in res) CameraAhead(camera: cams[i], routeMeters: m),
  ];
}

/// Top-level (isolate-safe) worker for [camerasAheadOnRoute]: returns
/// (camera index, along-route metres) pairs for cameras ahead of [current],
/// ordered by distance.
List<(int, double)> _camerasAheadOnRoute(
  (LatLng, List<LatLng>, List<OfflineCamera>, double) args,
) {
  final (current, geometry, cams, maxAheadMeters) = args;
  final out = <(int, double)>[];
  for (var i = 0; i < cams.length; i++) {
    final c = cams[i];
    // Quick reject: straight-line farther than max ahead → can't be "ahead".
    if (c.distanceM(current) > maxAheadMeters + 500) continue;
    final m = _routeMetersAhead(current, c.pos, geometry);
    if (m != null && m >= 0 && m <= maxAheadMeters) {
      out.add((i, m));
    }
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

/// Cameras within ~[corridorMeters] of the route polyline — the map layer
/// shows ONLY these (not all ~1,800 nationwide cameras), so the driver sees
/// the cameras that are actually on/near the road they're taking.
///
/// The heavy projection runs in a BACKGROUND ISOLATE ([compute]) so a LONG
/// route can never block the UI thread. This used to iterate every camera ×
/// every polyline vertex synchronously on the main isolate — for a ~191 km
/// route that froze the app for seconds and triggered the Android ANR
/// ("app isn't responding" → sometimes "app has stopped").
Future<List<OfflineCamera>> camerasNearRoute(
  List<LatLng> geometry, {
  double corridorMeters = 200,
}) async {
  final cams = await loadOfflineCameras();
  if (cams.isEmpty || geometry.length < 2) return const [];
  final idxs = await compute(_camerasNearRoute, (
    geometry,
    cams,
    corridorMeters,
  ));
  return [for (final i in idxs) cams[i]];
}

/// Top-level (isolate-safe) worker: returns the indices of [cams] that lie
/// within ~[corridorMeters] of the [geometry] polyline. Runs off the UI
/// isolate so route length never freezes the app.
///
/// Two cheap pre-filters keep the O(polyline) exact scan tiny:
///   1. Bounding box: a camera outside the route's padded box is skipped.
///   2. Coarse corridor: straight-line distance to a DECIMATED polyline with
///      a LOOSE threshold — rejects cameras inside the bbox but far from the
///      road, so `_nearestAlong` (the expensive exact scan) only runs for
///      the few survivors.
List<int> _camerasNearRoute((List<LatLng>, List<OfflineCamera>, double) args) {
  final (geometry, cams, corridorMeters) = args;
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
  for (var i = 0; i < cams.length; i++) {
    final c = cams[i];
    if (c.lat < loLat || c.lat > hiLat || c.lng < loLng || c.lng > hiLng) {
      continue; // outside the route's padded bounding box — cannot be near it
    }
    // Coarse pre-filter (see doc above).
    if (!_withinCoarseCorridor(geometry, c.pos, corridorMeters)) continue;
    // `_nearestAlong` returns null when the camera is >200 m from the
    // polyline (i.e. on a parallel/adjacent street) — exactly the corridor
    // filter we want.
    if (_nearestAlong(geometry, c.pos) != null) {
      out.add(i);
    }
  }
  return out;
}

/// Cheap test: is [p] within roughly [corridorMeters] of the polyline,
/// using a decimated polyline + a straight-line distance check? Returns
/// false for cameras clearly far from the road, so the expensive exact
/// projection in [_nearestAlong] only runs for the few candidates that might
/// actually be on/near the route.
///
/// Decimation is ADAPTIVE: long polylines (e.g. a 191 km route with tens of
/// thousands of vertices) are sampled down to ~[kCoarseTarget] vertices so
/// the check stays O(samples) per camera, while short routes check every
/// vertex (no decimation) so a camera mid-route is never missed.
///
/// Deliberately LOOSE (corridor × 3) so it never rejects a camera the exact
/// scan would accept.
const int kCoarseTarget = 256;
bool _withinCoarseCorridor(List<LatLng> geo, LatLng p, double corridorMeters) {
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
double? _routeMetersAhead(LatLng from, LatLng target, List<LatLng> geo) {
  // Find along-route distance (from start) of the nearest points.
  final f = _nearestAlong(geo, from);
  final t = _nearestAlong(geo, target);
  if (f == null || t == null) return null;
  return t - f;
}

/// Cumulative distance from the polyline start to the nearest point on it to
/// [p]. Returns null if [p] is farther than 200m from the polyline (i.e. not
/// on the route — e.g. a camera on a parallel street).
double? _nearestAlong(List<LatLng> geo, LatLng p) {
  const Distance d = Distance();
  double bestDist = double.infinity;
  double bestCum = 0;
  double cum = 0;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final seg = d.as(LengthUnit.Meter, a, b);
    // Project p onto segment a-b (linear approx at city scale).
    final proj = _projectOnSegment(a, b, p);
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

LatLng _projectOnSegment(LatLng a, LatLng b, LatLng p) {
  // Planar projection (fine at city scale).
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
