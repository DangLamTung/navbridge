/// Offline speed/red-light camera index for Việt Nam — bundled as a compact
/// JSON (`assets/offline_map/vietnam_cameras.json`) generated from provincial
/// police "phạt nguội" (fine) lists + OSM Overpass.
///
/// Works with NO network (like `offline_poi.dart`). During navigation the app
/// finds the nearest camera AHEAD on the route and warns the driver
/// (voice + notification + PiP + ESP) when within a trigger distance.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'offline_loader.dart';
import 'offline_scan.dart';
import 'offline_scan_isolate.dart';

/// One offline camera / traffic-sign point.
class OfflineCamera implements OfflinePoint {
  final String name;
  final double lat;
  final double lng;

  /// `speed` | `red_light` | `violations` | `sign` — the alert focus.
  final String focus;

  /// REAL camera type when known (preserves the raw-source distinction the
  /// flattened `focus` loses): `speed_camera` | `traffic_camera` |
  /// `penalty_camera` | `red_light` | `speed_limit` | null. The voice uses
  /// this to say exactly what the camera is (e.g. "Camera phạt nguội" vs
  /// "Camera giám sát giao thông"), which `focus` alone can't tell apart.
  final String? type;

  /// Enforcement SEGMENT length in metres (Waze speed cameras are road
  /// segments — `dist_m` ≈ 300 m, not a single point). Null for points.
  final int? segmentMeters;

  /// Optional road-sign label (Waze tiles): no_passing, no_left_turn,
  /// residential_start, end_of_prohibitions, …
  final String? sign;

  /// Posted speed limit at this point, km/h (Waze speed cameras/signs).
  final int? speedLimit;

  /// Optional count of devices at the point (police lists).
  final int? devices;

  /// Optional district / province label.
  final String? district;

  /// Data source that produced this point: `waze` | `police` | `osm`.
  /// (Waze = community speed-camera tiles, police = phạt nguội fine lists,
  /// osm = OSM Overpass.) Shown on the map icon so the driver can trust a
  /// camera's origin.
  final String source;

  const OfflineCamera({
    required this.name,
    required this.lat,
    required this.lng,
    required this.focus,
    this.type,
    this.segmentMeters,
    this.sign,
    this.speedLimit,
    this.devices,
    this.district,
    this.source = 'osm',
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
    type: j['type'] as String?,
    segmentMeters: (j['segment_m'] as num?)?.toInt(),
    sign: j['sign'] as String?,
    speedLimit: (j['speed_limit'] as num?)?.toInt(),
    devices: (j['devices'] as num?)?.toInt(),
    district: j['district'] as String?,
    source: (j['source'] ?? 'osm') as String,
  );
}

/// A camera that is AHEAD of the driver on the route.
class CameraAhead {
  final OfflineCamera camera;

  /// Distance along the route (not straight-line) from the car, metres.
  final double routeMeters;

  const CameraAhead({required this.camera, required this.routeMeters});
}

final OfflineListLoader<OfflineCamera> _cameras =
    OfflineListLoader<OfflineCamera>(_fetchCameras);

/// Load the bundled camera index once (idempotent, cached).
Future<List<OfflineCamera>> loadOfflineCameras() => _cameras.load();

Future<List<OfflineCamera>> _fetchCameras() async {
  final raw = await rootBundle.loadString(
    'assets/offline_map/vietnam_cameras.json',
  );
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final it
        in (data['cameras'] as List? ?? const []).cast<Map<String, dynamic>>())
      OfflineCamera.fromJson(it),
  ];
}

/// Find cameras AHEAD of [current] along [geometry], ordered by distance along
/// the route. Only returns cameras within [maxAheadMeters] ahead.
///
/// Approach: walk the route polyline from the point nearest to [current];
/// for each camera, project it onto the polyline (nearest point) and compute
/// the along-route distance. Cameras behind the car are skipped.
///
/// Runs in a PERSISTENT BACKGROUND ISOLATE ([OfflineScanIsolate]) that keeps
/// the camera DB resident — a fresh `compute()` per call would deep-copy the
/// whole 8.6k-camera list onto the main thread EVERY second (~90 ms desktop /
/// several hundred ms on a low-end phone), which is exactly what froze the
/// app on long routes ("not responding").
Future<List<CameraAhead>> camerasAheadOnRoute(
  LatLng current,
  List<LatLng> geometry, {
  double maxAheadMeters = 1500,
}) async {
  return OfflineScanIsolate.instance.camerasAhead(
    current,
    geometry,
    maxAheadMeters: maxAheadMeters,
  );
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
  return OfflineScanIsolate.instance.camerasNear(
    geometry,
    corridorMeters: corridorMeters,
  );
}

/// Cameras within [maxDistM] of a POINT — the nav-map camera layer WHILE
/// DRIVING only needs the handful near the car. A long route's route-wide
/// layer can be 100+ cameras, and each is drawn as 4 native maplibre circles
/// (glow/body/lens/pupil) — 400+ platform-channel annotations held even
/// off-screen crushed the low-end phone at large zoom. Bounded near-car set,
/// refreshed every few seconds. Cheap bbox pre-filter, main-thread safe.
Future<List<OfflineCamera>> camerasNearPoint(
  LatLng pos, {
  double maxDistM = 6000,
}) async {
  final cams = await loadOfflineCameras();
  if (cams.isEmpty) return const [];
  const Distance d = Distance();
  final span = maxDistM / 111320.0;
  final out = <OfflineCamera>[];
  for (final c in cams) {
    if (c.lat < pos.latitude - span ||
        c.lat > pos.latitude + span ||
        c.lng < pos.longitude - span ||
        c.lng > pos.longitude + span) {
      continue;
    }
    if (d.as(LengthUnit.Meter, pos, c.pos) <= maxDistM) out.add(c);
  }
  return out;
}

/// Result cache for [isCameraConfirmed] (keyed by source + lat,lng) so the
/// overlap scan only runs once per police camera, not every nav fix.
final Map<String, bool> _cameraConfirmCache = {};

/// Is this camera CONFIRMED enough to call out as a definite "Camera …"?
///
/// A police (CSGT) phạt nguội point is a MANUAL report — lots of them are
/// stale or estimated. It's only treated as confirmed when a Waze or VietMap
/// camera sits at the same spot (those come from official / community
/// databases). A lone CSGT point is announced as "có thể có camera" instead.
/// Non-police points (Waze / VietMap / OSM) are always confirmed.
Future<bool> isCameraConfirmed(OfflineCamera cam) async {
  if (cam.source != 'police') return true;
  final key = '${cam.source}:${cam.lat},${cam.lng}';
  final cached = _cameraConfirmCache[key];
  if (cached != null) return cached;
  final near = await camerasNearPoint(cam.pos, maxDistM: 150);
  final confirmed = near.any(
    (o) => o.source == 'vietmap' || o.source == 'waze',
  );
  _cameraConfirmCache[key] = confirmed;
  return confirmed;
}

/// Camera distances (metres) for the floating widget: EVERY camera within
/// [maxDistM] (600 m), sorted nearest first; if none is that close yet, the
/// SINGLE nearest camera up to 1 km is still surfaced (so an approaching
/// camera keeps alerting ahead — the old widget showed the nearest ≤1 km, so
/// a camera at 700 m must not disappear). Capped at [max].
Future<List<int>> camerasForWidgetChips(
  LatLng pos, {
  double maxDistM = 600,
  int max = 4,
}) async {
  final cams = await camerasNearPoint(pos, maxDistM: 1000);
  if (cams.isEmpty) return const [];
  const Distance d = Distance();
  final all = <(int, double)>[];
  for (final c in cams) {
    final m = d.as(LengthUnit.Meter, pos, c.pos);
    all.add((m.round(), m));
  }
  all.sort((a, b) => a.$2.compareTo(b.$2));
  final within = [
    for (final (m, _) in all)
      if (m <= maxDistM) m,
  ];
  final out = within.isEmpty ? [all.first.$1] : within;
  return out.length > max ? out.sublist(0, max) : out;
}

// Route scanning (`pointsAheadOnRoute` / `pointsNearRoute`) lives in
// `offline_scan.dart`; polyline helpers live in `offline_geo.dart`.
