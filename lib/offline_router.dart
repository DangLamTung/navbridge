/// On-device offline routing via GraphHopper (MethodChannel → Kotlin).
///
/// A pre-built car graph (a `.ghz` zip or an extracted folder) is downloaded
/// once and loaded into GraphHopper on the device; then any A→B (or multi-stop)
/// route can be computed fully offline, including re-routing.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_tiles.dart' show forceOffline, isOnline;
import 'osrm.dart';
import 'route_profile.dart';
import 'vietmap_config.dart' show dataSource;
import 'vietmap_router.dart';

const MethodChannel _channel = MethodChannel('navbridge/routing');

class OfflineRouter {
  OfflineRouter._();

  static final OfflineRouter instance = OfflineRouter._();

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Load the graph at [graphPath] (a folder, or a `.ghz` zip — the native
  /// side extracts it). Returns true when routing is ready.
  Future<bool> load(String graphPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('load', {'dir': graphPath});
      _loaded = ok ?? false;
      return _loaded;
    } catch (e) {
      debugPrint('ROUTER: load error: $e');
      return false;
    }
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
      final raw = await _channel.invokeMethod<Object?>(
          'roadInfo', {'lat': pos.latitude, 'lng': pos.longitude});
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw as Map);
    } catch (e) {
      debugPrint('ROUTER: roadInfo error: $e');
      return null;
    }
  }

  /// Compute a route through [points] (2+) entirely on-device.
  Future<OsrmRoute?> route(List<LatLng> points) async {
    if (points.length < 2 || !_loaded) return null;
    try {
      final flat = <double>[];
      for (final p in points) {
        flat.add(p.latitude);
        flat.add(p.longitude);
      }
      // Platform-channel maps decode as Map<Object?, Object?>, so a typed
      // invokeMapMethod<String, dynamic> cast throws. Convert explicitly.
      final raw = await _channel.invokeMethod<Object?>('route', {'points': flat});
      if (raw == null) return null;
      final res = Map<String, dynamic>.from(raw as Map);
      return _parse(res);
    } catch (e) {
      debugPrint('ROUTER: route error: $e');
      return null;
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
      steps.add(OsrmStep(
        name: (s['name'] ?? '') as String,
        distance: ((s['distance'] ?? 0) as num).toDouble(),
        duration: ((s['duration'] ?? 0) as num).toDouble(),
        type: type,
        modifier: modifier,
        maneuver: LatLng(((s['lat'] ?? 0) as num).toDouble(),
            ((s['lng'] ?? 0) as num).toDouble()),
      ));
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

/// Path to pass to the loader: the `.ghz` file if present, else the folder.
Future<String> routingGraphPath() async {
  final dir = await routingGraphDir();
  return File('$dir.ghz').existsSync() ? '$dir.ghz' : dir;
}

Future<bool> routingGraphPresent() async {
  final dir = await routingGraphDir();
  final d = Directory(dir);
  return (d.existsSync() && d.listSync().isNotEmpty) ||
      File('$dir.ghz').existsSync();
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
    req.headers['User-Agent'] = 'navbridge/1.0 (BLE portable navigation; graph)';
    final streamed = await client.send(req).timeout(const Duration(seconds: 30));
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
}) async {
  if (dataSource == 'vietmap' &&
      !forceOffline &&
      (profile == RouteProfile.car || profile == RouteProfile.motorbike)) {
    try {
      return await fetchVietmapRoute(
        points,
        vehicle: profile == RouteProfile.motorbike ? 'motorcycle' : 'car',
      );
    } catch (e) {
      debugPrint('VIETMAP: route failed: $e — falling back to OSRM');
    }
  }
  if (profile == RouteProfile.car && OfflineRouter.instance.isLoaded) {
    final local = await OfflineRouter.instance.route(points);
    if (local != null) return local;
  }
  if (forceOffline) {
    throw StateError(profile == RouteProfile.car
        ? 'Ngoại tuyến: chưa tải bộ dữ liệu chỉ đường'
        : 'Ngoại tuyến: bộ dữ liệu chỉ hỗ trợ ô tô');
  }
  return fetchOsrmRoute(points, profile: profile.osrm);
}

/// True when on-device routing could be used right now (loaded graph).
Future<bool> localRoutingAvailable() async {
  if (OfflineRouter.instance.isLoaded) return true;
  if (!await isOnline()) {
    // offline + graph present but not loaded yet → try to load it
    if (await routingGraphPresent()) {
      return OfflineRouter.instance.load(await routingGraphDir());
    }
  }
  return false;
}
