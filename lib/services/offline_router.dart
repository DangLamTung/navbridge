/// On-device offline routing via GraphHopper (MethodChannel → Kotlin).
///
/// A pre-built car graph (a `.ghz` zip or an extracted folder) is downloaded
/// once and loaded into GraphHopper on the device; then any A→B (or multi-stop)
/// route can be computed fully offline, including re-routing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_tiles.dart' show forceOffline, routingEngine;
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/core/route_profile.dart';
import 'vietmap_config.dart' show dataSource, graphDownloadBaseUrl;
import 'package:navbridge/services/vietmap_router.dart';
import 'package:navbridge/services/google_router.dart';

const MethodChannel _channel = MethodChannel('navbridge/routing');

/// Result of snapping a GPS fix to the nearest road in the offline graph
/// (network matching — like Google Maps' blue dot snapping to the road).
class SnapResult {
  final double lat;
  final double lng;
  final double distance; // meters from the fix to the road
  final int edge; // graph edge id of the snapped road
  const SnapResult({
    required this.lat,
    required this.lng,
    required this.distance,
    required this.edge,
  });
}

class OfflineRouter {
  OfflineRouter._();

  static final OfflineRouter instance = OfflineRouter._();

  bool _loaded = false;
  bool get isLoaded => _loaded;
  Completer<void>? _loadCompleter;

  /// Completes once the graph has finished loading (or failed to load).
  /// Offline routing awaits this so it doesn't fail while the graph is still
  /// loading at startup (it can take ~60 s on low-end phones).
  Future<void> get ready {
    if (_loaded) return Future.value();
    final c = _loadCompleter;
    if (c == null) return Future.value();
    return c.future;
  }

  /// Load the graph at [graphPath] (a folder, or a `.ghz` zip — the native
  /// side extracts it). Returns true when routing is ready.
  Future<bool> load(String graphPath) async {
    // Reset every attempt: after a failed load the completer must not stay
    // completed, or [ready] would report "done" before the graph loaded.
    _loadCompleter = Completer<void>();
    try {
      final ok = await _channel.invokeMethod<bool>('load', {'dir': graphPath});
      _loaded = ok ?? false;
      if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
      return _loaded;
    } catch (e) {
      debugPrint('ROUTER: load error: $e');
      if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
      return false;
    }
  }

  /// Unload the routing engine and release file handles.
  Future<void> unload() async {
    try {
      await _channel.invokeMethod('unload');
    } catch (_) {}
    _loaded = false;
    _loadCompleter = null;
  }

  /// Ask the native side whether a graph is already loaded (e.g. after the
  /// process restarted).
  Future<bool> refreshLoaded() async {
    try {
      _loaded = await _channel.invokeMethod<bool>('isLoaded') ?? false;
    } catch (_) {}
    return _loaded;
  }

  /// Road info (name / road class / maxspeed) at [pos] straight from the
  /// on-device graph — instant and offline. Returns null when unavailable.
  Future<Map<String, dynamic>?> roadInfo(LatLng pos) async {
    if (!_loaded) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('roadInfo', {
        'lat': pos.latitude,
        'lng': pos.longitude,
      });
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw as Map);
    } catch (e) {
      debugPrint('ROUTER: roadInfo error: $e');
      return null;
    }
  }

  /// Google-style network match: snap [pos] to the nearest ROAD in the
  /// offline graph. Returns the snapped point + the graph edge id (so the
  /// caller can tell whether that road is part of the current route), or
  /// null when no road is nearby. Instant + offline.
  Future<SnapResult?> snapToRoad(LatLng pos) async {
    if (!_loaded) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('snapToRoad', {
        'lat': pos.latitude,
        'lng': pos.longitude,
      });
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      final edge = (m['edge'] as num?)?.toInt();
      if (lat == null || lng == null || edge == null) return null;
      return SnapResult(
        lat: lat,
        lng: lng,
        distance: (m['distance'] as num?)?.toDouble() ?? 0,
        edge: edge,
      );
    } catch (e) {
      debugPrint('ROUTER: snapToRoad error: $e');
      return null;
    }
  }

  /// Compute up to [maxAlternatives] routes through [points] (2+) entirely
  /// on-device (best first). [avoidMotorway]/[avoidFerry] block those road
  /// classes via a GraphHopper custom model. Returns [] when unavailable.
  Future<List<OsrmRoute>> route(
    List<LatLng> points, {
    int maxAlternatives = 1,
    bool avoidMotorway = false,
    bool avoidFerry = false,
    double? startHeading,
  }) async {
    if (points.length < 2 || !_loaded) return const [];
    try {
      final flat = <double>[];
      for (final p in points) {
        flat.add(p.latitude);
        flat.add(p.longitude);
      }
      final args = <String, dynamic>{
        'points': flat,
        'alternatives': maxAlternatives,
        'avoidMotorway': avoidMotorway,
        'avoidFerry': avoidFerry,
      };
      if (startHeading != null) args['heading'] = startHeading;
      // Platform-channel maps decode as Map<Object?, Object?>, so a typed
      // invokeMapMethod<String, dynamic> cast throws. Convert explicitly.
      final raw = await _channel
          .invokeMethod<Object?>('route', args)
          .timeout(const Duration(seconds: 90));
      if (raw == null) {
        debugPrint('ROUTER: route returned null (no path)');
        return const [];
      }
      // Kotlin returns a plain List of Maps (best first).
      final rawList = (raw as List).cast<Object?>();
      debugPrint('ROUTER: offline route paths=${rawList.length}');
      return [
        for (final r in rawList) _parse(Map<String, dynamic>.from(r as Map)),
      ];
    } on TimeoutException {
      debugPrint('ROUTER: offline route TIMED OUT (90s)');
      return const [];
    } catch (e) {
      debugPrint('ROUTER: route error: $e');
      return const [];
    }
  }

  OsrmRoute _parse(Map<String, dynamic> res) {
    final flat = (res['points'] as List).cast<num>();
    final geometry = <LatLng>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      geometry.add(LatLng(flat[i].toDouble(), flat[i + 1].toDouble()));
    }
    // Steps arrive as List<Map<Object?, Object?>> — convert each explicitly
    // (List.cast<Map<String, dynamic>>() would throw on iteration).
    final rawSteps = (res['steps'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final steps = <OsrmStep>[];
    for (final s in rawSteps) {
      final sign = ((s['sign'] ?? 0) as num).toInt();
      final (type, modifier) = _maneuverForSign(sign);
      steps.add(
        OsrmStep(
          name: (s['name'] ?? '') as String,
          distance: ((s['distance'] ?? 0) as num).toDouble(),
          duration: ((s['duration'] ?? 0) as num).toDouble(),
          type: type,
          modifier: modifier,
          maneuver: LatLng(
            ((s['lat'] ?? 0) as num).toDouble(),
            ((s['lng'] ?? 0) as num).toDouble(),
          ),
        ),
      );
    }
    // Stop boundaries: instructions with sign 5 (REACHED_VIA) / 4 (FINISH).
    final stopCum = <double>[];
    var c = 0.0;
    for (final s in rawSteps) {
      final sign = ((s['sign'] ?? 0) as num).toInt();
      c += ((s['distance'] ?? 0) as num).toDouble();
      if (sign == 5 || sign == 4) stopCum.add(c);
    }
    if (stopCum.isEmpty && c > 0) stopCum.add(c);
    return OsrmRoute(
      distance: ((res['distance'] ?? 0) as num).toDouble(),
      duration: ((res['duration'] ?? 0) as num).toDouble(),
      geometry: geometry,
      steps: steps,
      stopCumulative: stopCum,
    );
  }

  // GraphHopper instruction sign → OSRM-style maneuver.
  (String, String?) _maneuverForSign(int sign) => switch (sign) {
    -8 || -98 => ('turn', 'uturn'),
    -3 => ('turn', 'sharp left'),
    -2 => ('turn', 'left'),
    -1 => ('turn', 'slight left'),
    0 => ('continue', 'straight'),
    1 => ('turn', 'slight right'),
    2 => ('turn', 'right'),
    3 => ('turn', 'sharp right'),
    8 => ('turn', 'uturn'),
    4 || 5 => ('arrive', null),
    6 || 7 => ('roundabout', 'left'),
    _ => ('continue', 'straight'),
  };
}

// ---- graph storage / download -------------------------------------------

/// Folder that holds the extracted GraphHopper graph.
Future<String> routingGraphDir() async {
  final sup = await getApplicationSupportDirectory();
  return '${sup.path}/routing_graph';
}

/// Delete the on-device routing graph and all downloaded source files to free phone storage.
Future<void> deleteRoutingGraph() async {
  await OfflineRouter.instance.unload();
  final dir = await routingGraphDir();
  final d = Directory(dir);
  if (d.existsSync()) {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  }
  for (final ext in ['.ghz', '.osm.pbf', '.pbf', '.zip']) {
    final f = File('$dir$ext');
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

/// Path to pass to the loader: the extracted directory if populated,
/// or a `.ghz` / `.osm.pbf` file (which will be converted on-device and deleted).
Future<String> routingGraphPath() async {
  final dir = await routingGraphDir();
  final d = Directory(dir);
  if (d.existsSync()) {
    try {
      if (d.listSync().isNotEmpty) return dir;
    } catch (_) {}
  }
  for (final ext in ['.ghz', '.osm.pbf', '.pbf', '.zip']) {
    final local = File('$dir$ext');
    if (local.existsSync()) return local.path;
  }
  // Also check external storage / Download directory if user downloaded via browser or pushed via ADB
  for (final p in [
    '/sdcard/Download/routing_graph.ghz',
    '/sdcard/Download/graph.ghz',
    '/sdcard/Download/vietnam-latest.osm.pbf',
    '/sdcard/Download/vietnam.osm.pbf',
    '/sdcard/Download/saigon-latest.osm.pbf',
    '/storage/emulated/0/Download/routing_graph.ghz',
    '/storage/emulated/0/Download/graph.ghz',
    '/storage/emulated/0/Download/vietnam-latest.osm.pbf',
  ]) {
    final f = File(p);
    if (f.existsSync()) {
      try {
        final ext = p.endsWith('.osm.pbf')
            ? '.osm.pbf'
            : p.substring(p.lastIndexOf('.'));
        final target = File('$dir$ext');
        if (!target.existsSync() || target.lengthSync() != f.lengthSync()) {
          target.parent.createSync(recursive: true);
          f.copySync(target.path);
          // Delete from /sdcard/Download after copying to reclaim download storage
          try {
            f.deleteSync();
          } catch (_) {}
        }
        return target.path;
      } catch (_) {
        return f.path;
      }
    }
  }
  return File('$dir.ghz').existsSync() ? '$dir.ghz' : dir;
}

Future<bool> routingGraphPresent() async {
  final dir = await routingGraphDir();
  final d = Directory(dir);
  var nonEmpty = false;
  try {
    await for (final _ in d.list(followLinks: false)) {
      nonEmpty = true;
      break;
    }
  } catch (_) {}
  if (nonEmpty) return true;
  for (final ext in ['.ghz', '.osm.pbf', '.pbf', '.zip']) {
    if (File('$dir$ext').existsSync()) return true;
  }
  for (final p in [
    '/sdcard/Download/routing_graph.ghz',
    '/sdcard/Download/graph.ghz',
    '/sdcard/Download/vietnam-latest.osm.pbf',
    '/sdcard/Download/vietnam.osm.pbf',
    '/sdcard/Download/saigon-latest.osm.pbf',
    '/storage/emulated/0/Download/routing_graph.ghz',
    '/storage/emulated/0/Download/graph.ghz',
    '/storage/emulated/0/Download/vietnam-latest.osm.pbf',
  ]) {
    if (File(p).existsSync()) return true;
  }
  return false;
}

/// Download the GraphHopper routing data directly on the phone,
/// convert it into the offline graph, and delete the downloaded file to save storage.
Future<bool> downloadGraph([
  void Function(int done, int total)? onProgress,
  String? customUrl,
]) async {
  final urlStr = (customUrl != null && customUrl.isNotEmpty)
      ? customUrl
      : (graphDownloadBaseUrl.isNotEmpty
          ? (graphDownloadBaseUrl.endsWith('.ghz') ||
                  graphDownloadBaseUrl.endsWith('.pbf')
              ? graphDownloadBaseUrl
              : '$graphDownloadBaseUrl/graph.ghz')
          : 'https://download.geofabrik.de/asia/vietnam-latest.osm.pbf');

  final dir = await routingGraphDir();
  final isPbf = urlStr.contains('.pbf');
  final target = isPbf ? '$dir.osm.pbf' : '$dir.ghz';
  final ok = await downloadToFile(
    urlStr,
    target,
    onProgress ?? (_, _) {},
  );
  if (!ok) {
    throw StateError('Không tải được bộ dữ liệu GraphHopper ($urlStr).');
  }
  // Convert/extract on the phone. Once converted, the native loader automatically deletes the downloaded file!
  return OfflineRouter.instance.load(target);
}

/// Download [url] to [target] with byte progress; returns true on success.
Future<bool> downloadToFile(
  String url,
  String target,
  void Function(int done, int total) onProgress,
) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] =
        'navbridge/1.0 (BLE portable navigation; graph)';
    final streamed = await client
        .send(req)
        .timeout(const Duration(seconds: 30));
    final total = streamed.contentLength ?? 0;
    if (streamed.statusCode != 200) return false;
    final file = File(target);
    file.createSync(recursive: true);
    final sink = file.openWrite();
    var done = 0;
    await for (final chunk in streamed.stream) {
      sink.add(chunk);
      done += chunk.length;
      onProgress(done, total);
    }
    await sink.close();
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// Best route source: on-device GraphHopper when loaded, OSRM otherwise.
/// In forced-offline mode only the on-device graph is used (never OSRM).
/// Snap a GPS trace to the road with OSRM's match API — but ONLY when online
/// (the on-device graph has no matching). Returns the snapped point or null.
Future<LatLng?> fetchAnyMatch(List<LatLng> trace) async {
  if (forceOffline) return null;
  return matchGpsTrace(trace);
}

/// Bearing (deg, 0=N) from [a] to [b] — used by the scenic curvature score.
double _bearing(LatLng a, LatLng b) {
  final dLon = (b.longitude - a.longitude) * 0.017453292519943295;
  final lat1 = a.latitude * 0.017453292519943295;
  final lat2 = b.latitude * 0.017453292519943295;
  final y = math.sin(dLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return (math.atan2(y, x) * 57.29577951308232 + 360) % 360;
}

/// Scenic score of a route = total absolute heading change (degrees) along
/// the polyline. Winding routes (hills / coast / old town) score higher — the
/// "đẹp cảnh" preference picks the curviest of the alternatives.
double _routeCurvature(OsrmRoute r) {
  final g = r.geometry;
  if (g.length < 3) return 0;
  var sum = 0.0;
  for (var i = 1; i < g.length - 1; i++) {
    var d = (_bearing(g[i - 1], g[i]) - _bearing(g[i], g[i + 1])).abs() % 360;
    if (d > 180) d = 360 - d;
    sum += d;
  }
  return sum;
}

/// Re-order [routes] so the one matching [pref] is first. "Nhanh nhất" keeps
/// the backend's duration-optimised order. Best-effort: only meaningful when
/// the source returned >1 alternatives (the on-device car graph returns one
/// fastest route → unchanged).
List<OsrmRoute> rankByPreference(List<OsrmRoute> routes, RoutePreference pref) {
  if (routes.length < 2 || pref == RoutePreference.fastest) return routes;
  final ranked = [...routes];
  switch (pref) {
    case RoutePreference.shortest:
      ranked.sort((a, b) => a.distance.compareTo(b.distance));
    case RoutePreference.mainRoads:
      // Main roads → fewer, longer legs (motorway/trunk/primary): highest
      // average step length wins. Heuristic over the alternatives we have.
      double avg(OsrmRoute r) =>
          r.distance / (r.steps.length > 1 ? r.steps.length : 1);
      ranked.sort((a, b) => avg(b).compareTo(avg(a)));
    case RoutePreference.scenic:
      ranked.sort((a, b) => _routeCurvature(b).compareTo(_routeCurvature(a)));
    case RoutePreference.fastest:
      break;
  }
  return ranked;
}

/// Throws when no source is available (fully offline without a graph).
///
/// [profile] selects the road type (car / motorbike / bicycle / walking).
/// The on-device graph is car-only: car routes use it; other profiles always
/// route online (OSRM) so the path matches the chosen mode of transport.
/// With the Vietmap data source active, car + motorbike route on Vietmap
/// (fast, VN-optimized, live congestion); bicycle/walking stay on OSRM.
Future<OsrmRoute> fetchAnyRoute(
  List<LatLng> points, {
  RouteProfile profile = RouteProfile.car,
  bool avoidHighway = false,
  bool avoidFerry = false,
  RoutePreference preference = RoutePreference.fastest,
  Duration? onlineTimeout,
  double? startHeading,
}) async {
  final routes = await fetchAnyRoutes(
    points,
    profile: profile,
    avoidHighway: avoidHighway,
    avoidFerry: avoidFerry,
    preference: preference,
    onlineTimeout: onlineTimeout,
    startHeading: startHeading,
  );
  return routes.first;
}

/// Like [fetchAnyRoute] but returns up to [maxAlternatives] route options
/// (best first) when the active source can produce alternatives (OSRM
/// `alternatives=` or Vietmap `alternative=true`). The on-device car graph
/// returns a single route.
/// [avoidHighway] / [avoidFerry] re-route without motorways / ferries
/// (OSRM `exclude=motorway,ferry`); the on-device car graph and Vietmap
/// don't support exclusions, so they're ignored there.
///
/// [onlineTimeout] caps how long an ONLINE attempt (Google / Vietmap) may
/// take before falling through to the on-device graph / OSRM. Live off-route
/// reroutes pass a short budget so a dead zone (tunnel / rural) can't freeze
/// turn-by-turn guidance for 30–60 s waiting on a network that is gone.
/// [startHeading] = departure vehicle bearing (degrees) to guide reroutes along
/// the current direction of travel.
Future<List<OsrmRoute>> fetchAnyRoutes(
  List<LatLng> points, {
  RouteProfile profile = RouteProfile.car,
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
  RoutePreference preference = RoutePreference.fastest,
  Duration? onlineTimeout,
  double? startHeading,
}) async {
  // Xe mô tô is PROHIBITED on VN motorways — the OSRM `motorcycle` profile and
  // Vietmap's `vehicle=motorcycle` account for that natively; the car
  // `driving` profile still honours the user's "avoid highway" toggle via
  // `exclude=motorway`.
  if (dataSource == 'google' && !forceOffline) {
    try {
      final fut = profile == RouteProfile.motorbike
          ? fetchGoogleTwoWheelerRoutes(
              points,
              maxAlternatives: maxAlternatives,
            )
          : fetchGoogleRoutes(points, maxAlternatives: maxAlternatives);
      final routes = onlineTimeout == null
          ? await fut
          : await fut.timeout(onlineTimeout);
      return rankByPreference(routes, preference);
    } catch (e) {
      debugPrint('GOOGLE: route failed: $e — falling back to OSRM');
    }
  }
  if (dataSource == 'vietmap' &&
      !forceOffline &&
      (profile == RouteProfile.car || profile == RouteProfile.motorbike)) {
    try {
      final fut = fetchVietmapRoutes(
        points,
        vehicle: profile == RouteProfile.motorbike ? 'motorcycle' : 'car',
        maxAlternatives: maxAlternatives,
      );
      final routes = onlineTimeout == null
          ? await fut
          : await fut.timeout(onlineTimeout);
      return rankByPreference(routes, preference);
    } catch (e) {
      debugPrint('VIETMAP: route failed: $e — falling back to OSRM');
    }
  }
  if (profile == RouteProfile.car && routingEngine != 'osrm') {
    // Wait for the on-device graph if it's still loading at startup (it can
    // take ~60 s on low-end phones), so offline routing doesn't fail early.
    await OfflineRouter.instance.ready;
    if (OfflineRouter.instance.isLoaded) {
      final local = await OfflineRouter.instance.route(
        points,
        maxAlternatives: maxAlternatives,
        avoidMotorway: avoidHighway,
        avoidFerry: avoidFerry,
        startHeading: startHeading,
      );
      if (local.isNotEmpty) return rankByPreference(local, preference);
    }
  }
  if (forceOffline || routingEngine == 'graphhopper') {
    throw StateError(
      profile == RouteProfile.car
          ? 'Ngoại tuyến: chưa tải bộ dữ liệu chỉ đường'
          : 'Ngoại tuyến: bộ dữ liệu chỉ hỗ trợ ô tô',
    );
  }
  // Online OSRM returns up to [maxAlternatives] tap-to-choose routes.
  return rankByPreference(
    await fetchOsrmRoutes(
      points,
      profile: profile.osrm,
      exclude: osrmExclude(
        // The OSRM `motorcycle` profile already keeps two-wheelers off
        // motorways; `exclude=motorway` is unsupported on that profile.
        avoidHighway: avoidHighway && profile != RouteProfile.motorbike,
        avoidFerry: avoidFerry,
      ),
      maxAlternatives: maxAlternatives,
      timeout: onlineTimeout,
      startBearing: startHeading != null ? (startHeading, 45.0) : null,
    ),
    preference,
  );
}
