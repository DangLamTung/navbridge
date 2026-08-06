/// Route elevation profile (cumulative ascent/descent) via the free
/// OpenTopoData SRTM service — no API key needed.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'terrain.dart' show routeTerrainProfile;

/// Cumulative elevation change along a route.
class ElevationInfo {
  final double up; // meters climbed
  final double down; // meters descended
  final double? minElev;
  final double? maxElev;

  /// (distanceMeters, elevationMeters) samples along the route — drives the
  /// elevation chart on the nav screen. Empty when only totals are known.
  final List<(double, double)> profile;
  const ElevationInfo({
    required this.up,
    required this.down,
    this.minElev,
    this.maxElev,
    this.profile = const [],
  });
}

/// Fetch the elevation profile of [poly] and return the total ascent and
/// descent. Prefers the OFFLINE DEM (downloaded Terrarium tiles — no network,
/// works in mountain regions); falls back to the free OpenTopoData SRTM
/// service when offline data is missing. Samples ~120 m apart. Returns null
/// on failure — elevation is best-effort info, never fatal.
Future<ElevationInfo?> fetchRouteElevation(List<LatLng> poly) async {
  if (poly.length < 2) return null;
  // Offline-first: sample the on-device terrain tiles.
  try {
    final t = await routeTerrainProfile(poly);
    if (t != null) {
      debugPrint(
        'ELEV: offline DEM up=${t.up.toStringAsFixed(0)} '
        'down=${t.down.toStringAsFixed(0)} '
        'min=${t.minElev.toStringAsFixed(0)} max=${t.maxElev.toStringAsFixed(0)}',
      );
      return ElevationInfo(
        up: t.up,
        down: t.down,
        minElev: t.minElev,
        maxElev: t.maxElev,
        profile: t.profile,
      );
    }
  } catch (_) {
    // fall through to the online service
  }
  try {
    // Sample ~120 m apart, max ~60 points for the free SRTM endpoint.
    final pts = <LatLng>[poly.first];
    final dists = <double>[0.0];
    var since = 0.0, acc = 0.0;
    for (var i = 1; i < poly.length && pts.length < 60; i++) {
      final seg = _dist(poly[i - 1], poly[i]);
      since += seg;
      acc += seg;
      if (since >= 120) {
        pts.add(poly[i]);
        dists.add(acc);
        since = 0;
      }
    }
    if (pts.length < 2) pts.add(poly.last);
    if (dists.length < pts.length) dists.add(acc);

    final locs = pts.map((p) => '${p.latitude},${p.longitude}').join('|');
    final url = 'https://api.opentopodata.org/v1/srtm90m?locations=$locs';
    final res = await http
        .get(
          Uri.parse(url),
          headers: const {'User-Agent': 'navbridge/1.0 (elevation)'},
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      debugPrint('ELEV: online failed status=${res.statusCode}');
      return null;
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final results = (data['results'] as List?) ?? const [];
    final elevs = <double>[];
    for (final r in results) {
      if (r is! Map) continue;
      final e = r['elevation'];
      if (e is num) elevs.add(e.toDouble());
    }
    if (elevs.length < 2) {
      debugPrint('ELEV: online too few samples (${elevs.length})');
      return null;
    }
    var up = 0.0, down = 0.0;
    var minE = elevs.first, maxE = elevs.first;
    final profile = <(double, double)>[];
    for (var i = 0; i < elevs.length; i++) {
      final e = elevs[i];
      if (e < minE) minE = e;
      if (e > maxE) maxE = e;
      final dist = i < dists.length ? dists[i] : dists.last;
      profile.add((dist, e));
      if (i == 0) continue;
      final diff = e - elevs[i - 1];
      if (diff > 0) {
        up += diff;
      } else {
        down += -diff;
      }
    }
    return ElevationInfo(
      up: up,
      down: down,
      minElev: minE,
      maxElev: maxE,
      profile: profile,
    );
  } catch (e) {
    debugPrint('ELEV: online error: $e');
    return null;
  }
}

double _dist(LatLng a, LatLng b) {
  const r = 6371000.0;
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(la1) * math.cos(la2) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}
