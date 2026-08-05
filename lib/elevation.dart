/// Route elevation profile (cumulative ascent/descent) via the free
/// OpenTopoData SRTM service — no API key needed.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Cumulative elevation change along a route.
class ElevationInfo {
  final double up; // meters climbed
  final double down; // meters descended
  const ElevationInfo({required this.up, required this.down});
}

/// Fetch the elevation profile of [poly] and return the total ascent and
/// descent. Samples the polyline every ~120 m (capped to keep the free API
/// happy). Returns null on failure (offline / service down) — elevation is
/// best-effort info, never fatal.
Future<ElevationInfo?> fetchRouteElevation(List<LatLng> poly) async {
  if (poly.length < 2) return null;
  try {
    // Sample ~120 m apart, max ~60 points for the free SRTM endpoint.
    final pts = <LatLng>[];
    pts.add(poly.first);
    var d = 0.0;
    for (var i = 1; i < poly.length && pts.length < 60; i++) {
      d += _dist(poly[i - 1], poly[i]);
      if (d >= 120) {
        pts.add(poly[i]);
        d = 0;
      }
    }
    if (pts.length < 2) pts.add(poly.last);

    final locs = pts.map((p) => '${p.latitude},${p.longitude}').join('|');
    final url = 'https://api.opentopodata.org/v1/srtm90m?locations=$locs';
    final res = await http
        .get(
          Uri.parse(url),
          headers: const {'User-Agent': 'navbridge/1.0 (elevation)'},
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final results = (data['results'] as List?) ?? const [];
    final elevs = <double>[];
    for (final r in results) {
      if (r is! Map) continue;
      final e = r['elevation'];
      if (e is num) elevs.add(e.toDouble());
    }
    if (elevs.length < 2) return null;
    var up = 0.0, down = 0.0;
    for (var i = 1; i < elevs.length; i++) {
      final diff = elevs[i] - elevs[i - 1];
      if (diff > 0) {
        up += diff;
      } else {
        down += -diff;
      }
    }
    return ElevationInfo(up: up, down: down);
  } catch (_) {
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
