/// Offline speed/red-light camera index for Việt Nam — bundled as a compact
/// JSON (`assets/offline_map/vietnam_cameras.json`) generated from provincial
/// police "phạt nguội" (fine) lists + OSM Overpass.
///
/// Works with NO network (like `offline_poi.dart`). During navigation the app
/// finds the nearest camera AHEAD on the route and warns the driver
/// (voice + notification + PiP + ESP) when within a trigger distance.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'offline_scan.dart';

/// One offline camera / traffic-sign point.
class OfflineCamera implements OfflinePoint {
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

  @override
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
  final res = await compute(pointsAheadOnRoute<OfflineCamera>, (
    current,
    geometry,
    cams,
    maxAheadMeters,
  ));
  return [
    for (final (i, m) in res) CameraAhead(camera: cams[i], routeMeters: m),
  ];
}

// The isolate workers (`pointsAheadOnRoute` / `pointsNearRoute`) live in
// `offline_scan.dart`; see [camerasAheadOnRoute] / [camerasNearRoute].

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
  final idxs = await compute(pointsNearRoute<OfflineCamera>, (
    geometry,
    cams,
    corridorMeters,
  ));
  return [for (final i in idxs) cams[i]];
}

// Route scanning (`pointsAheadOnRoute` / `pointsNearRoute`) lives in
// `offline_scan.dart`; polyline helpers live in `offline_geo.dart`.
