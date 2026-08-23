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

import 'offline_geo.dart';

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
    _loaded = true;
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
    final m = routeMetersAhead(current, c.pos, geometry);
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
    if (!withinCoarseCorridor(geometry, c.pos, corridorMeters)) continue;
    // `nearestAlong` returns null when the camera is >200 m from the
    // polyline (i.e. on a parallel/adjacent street) — exactly the corridor
    // filter we want.
    if (nearestAlong(geometry, c.pos) != null) {
      out.add(i);
    }
  }
  return out;
}

// Polyline helpers (`withinCoarseCorridor`, `routeMetersAhead`,
// `nearestAlong`, `projectOnSegment`) live in `offline_geo.dart`.
