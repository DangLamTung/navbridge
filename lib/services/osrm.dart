/// OSRM routing client — fetch a driving route with turn-by-turn steps.
///
/// Free public server (worldwide OSM data). For better Vietnam routing you can
/// point `baseUrl` at a self-hosted OSRM built from a Vietnam PBF
/// (see ../osrm/build.sh in the Eink workspace).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const String osrmPublic = 'https://router.project-osrm.org';

/// Real-world ETA buffer: OSRM/Vietmap durations assume ideal free-flow
/// speeds, so on real city streets (traffic, red lights, stops) the trip
/// takes noticeably longer than the static estimate. Applied to every
/// displayed ETA for a less optimistic arrival time.
const double kEtaRealismFactor = 1.3;

/// One turn-by-turn step: the maneuver at its start + the road after it.
class OsrmStep {
  final String name; // road name (after the maneuver)
  final double distance; // meters to the NEXT maneuver
  final double duration; // seconds to the next maneuver
  final String type; // depart | turn | new name | continue | merge | fork |
  // on ramp | off ramp | end of road | roundabout | exit roundabout |
  // roundabout turn | exit rotary | arrive | ...
  final String? modifier; // uturn | sharp right | right | slight right |
  // straight | slight left | left | sharp left
  final LatLng maneuver; // coordinate where the maneuver happens

  /// Live congestion level (0 low · 1 moderate · 2 heavy/severe), when the
  /// route came from a traffic-aware backend (Vietmap). Null = n/a.
  final int? congestion;

  OsrmStep({
    required this.name,
    required this.distance,
    required this.duration,
    required this.type,
    required this.modifier,
    required this.maneuver,
    this.congestion,
  });
}

/// One toll station on a route (Vietmap `tolls[]`).
class TollInfo {
  final String name;
  final String address;
  final String type; // 'entry' | 'exit'
  final int price; // VND charged at this station
  final String? roadName; // address/road the station is on

  const TollInfo({
    required this.name,
    required this.address,
    required this.type,
    required this.price,
    this.roadName,
  });

  /// Total toll for this route in VND (0 = no data).
  int get tollVnd => price;
}

/// A full OSRM route.
class OsrmRoute {
  final double distance; // meters
  final double duration; // seconds
  final List<LatLng> geometry; // full route polyline (decoded)
  final List<OsrmStep> steps;
  final List<double> stopCumulative; // meters along the polyline at each stop

  /// Total toll cost in VND (Vietmap only; null when the backend didn't
  /// provide toll data).
  final int? tollCost;

  /// Toll stations along the route (Vietmap only; empty otherwise).
  final List<TollInfo> tolls;

  OsrmRoute({
    required this.distance,
    required this.duration,
    required this.geometry,
    required this.steps,
    this.stopCumulative = const [],
    this.tollCost,
    this.tolls = const [],
  });
}

/// Decode a Google/OSRM encoded polyline (precision 5).
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0, lng = 0;
  final len = encoded.length;
  while (index < len) {
    var b = 0, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += dlat;
    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += dlng;
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// Fetch a driving route through [points] (2+ waypoints) with full geometry
/// and turn-by-turn steps. The route is one polyline; each intermediate stop
/// is reported via `stopCumulative` (meters along the polyline where that
/// waypoint is reached).
/// `baseUrl` — OSRM server root (defaults to the public demo server).
/// `profile` — OSRM routing profile: driving / cycling / walking.
/// `exclude` — road classes to avoid (e.g. 'motorway' / 'ferry'), OSRM `exclude=`.
Future<OsrmRoute> fetchOsrmRoute(
  List<LatLng> points, {
  String? baseUrl,
  bool steps = true,
  String profile = 'driving',
  String? exclude,
}) async {
  final routes = await fetchOsrmRoutes(
    points,
    baseUrl: baseUrl,
    steps: steps,
    profile: profile,
    exclude: exclude,
    maxAlternatives: 1,
  );
  return routes.first;
}

/// Like [fetchOsrmRoute] but returns up to [maxAlternatives] route options
/// (best first) via OSRM's `alternatives=` — Google/Vietmap-style tap-to-choose.
/// `exclude` may combine classes (e.g. 'motorway,ferry', most undesirable first).
Future<List<OsrmRoute>> fetchOsrmRoutes(
  List<LatLng> points, {
  String? baseUrl,
  bool steps = true,
  String profile = 'driving',
  String? exclude,
  int maxAlternatives = 3,
}) async {
  if (points.length < 2) {
    throw Exception('Cần ít nhất 2 điểm để định tuyến');
  }
  final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
  final base =
      '${baseUrl ?? osrmPublic}/route/v1/$profile/'
      '$coords?overview=full&geometries=polyline&steps=$steps';
  final altPart = maxAlternatives > 1
      ? '&alternatives=${maxAlternatives - 1}'
      : '';
  final exclPart = (exclude != null && exclude.isNotEmpty)
      ? '&exclude=$exclude'
      : '';
  // OSRM: `alternatives=N` = N alternatives IN ADDITION to the best route.
  var url = base + altPart + exclPart;
  var res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 20));
  // Some OSRM servers (e.g. the public demo) don't define exclude classes and
  // reject them with HTTP 400 — retry WITHOUT the exclusion rather than fail
  // the whole route (avoid-highway/ferry then only takes effect on servers
  // that support it).
  if (res.statusCode != 200 && exclPart.isNotEmpty) {
    url = base + altPart;
    res = await http
        .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
        .timeout(const Duration(seconds: 20));
  }
  if (res.statusCode != 200) {
    throw Exception('OSRM HTTP ${res.statusCode}');
  }
  // CRITICAL: parsing runs in a background ISOLATE. A LONG route returns a
  // massive JSON (tens of MB — the polyline can have 100k+ vertices); doing
  // utf8.decode + jsonDecode + geometry decode on the MAIN thread is what
  // froze the app ("long route → not responding").
  final routes = await compute(
    _parseOsrmRoutes,
    _RouteParseInput(res.bodyBytes, points.last),
  );
  if (routes.isEmpty) {
    throw Exception('Không tìm thấy tuyến đường');
  }
  return routes;
}

/// Input bundle for the isolate ([_parseOsrmRoutes]).
class _RouteParseInput {
  final Uint8List body;
  final LatLng fallbackManeuver;
  const _RouteParseInput(this.body, this.fallbackManeuver);
}

/// Top-level isolate worker: decode + parse the OSRM response into routes.
List<OsrmRoute> _parseOsrmRoutes(_RouteParseInput input) {
  final data = jsonDecode(utf8.decode(input.body));
  final routes = data['routes'] as List?;
  if (routes == null || routes.isEmpty) return const [];
  return [
    for (final r in routes.cast<Map<String, dynamic>>())
      _parseOsrmRoute(r, input.fallbackManeuver),
  ];
}

/// OSRM `exclude=` value built from the avoid flags (motorway / ferry).
/// Returns null when nothing is excluded.
String? osrmExclude({required bool avoidHighway, required bool avoidFerry}) {
  final parts = [if (avoidHighway) 'motorway', if (avoidFerry) 'ferry'];
  return parts.isEmpty ? null : parts.join(',');
}

OsrmRoute _parseOsrmRoute(Map<String, dynamic> r, LatLng fallbackManeuver) {
  final stepList = <OsrmStep>[];
  final stopCum = <double>[];
  var cum = 0.0;
  final legs = (r['legs'] as List? ?? []).cast<Map<String, dynamic>>();
  for (final leg in legs) {
    for (final s
        in (leg['steps'] as List? ?? []).cast<Map<String, dynamic>>()) {
      final m = (s['maneuver'] as Map<String, dynamic>? ?? {});
      final loc = (m['location'] as List?)?.cast<num>() ?? [];
      stepList.add(
        OsrmStep(
          name: (s['name'] ?? '') as String,
          distance: ((s['distance'] ?? 0) as num).toDouble(),
          duration: ((s['duration'] ?? 0) as num).toDouble(),
          type: (m['type'] ?? '') as String,
          modifier: m['modifier'] as String?,
          maneuver: loc.length >= 2
              ? LatLng(loc[1].toDouble(), loc[0].toDouble())
              : fallbackManeuver,
        ),
      );
    }
    cum += ((leg['distance'] ?? 0) as num).toDouble();
    stopCum.add(cum);
  }
  return OsrmRoute(
    distance: ((r['distance'] ?? 0) as num).toDouble(),
    duration: ((r['duration'] ?? 0) as num).toDouble(),
    geometry: decodePolyline((r['geometry'] ?? '') as String),
    steps: stepList,
    stopCumulative: stopCum,
  );
}

/// Snap a GPS trace to the road using OSRM's match API. Returns the latest
/// (last) matched point so the car can ride the road in online mode, or null
/// when the trace can't be matched (bad GPS / too few points / offline).
Future<LatLng?> matchGpsTrace(
  List<LatLng> trace, {
  String profile = 'driving',
  String? baseUrl,
}) async {
  if (trace.length < 2) return null;
  final coords = trace.map((p) => '${p.longitude},${p.latitude}').join(';');
  final url =
      '${baseUrl ?? osrmPublic}/match/v1/$profile/'
      '$coords?overview=full&geometries=polyline&tidy=true';
  try {
    final res = await http
        .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final matchings = data['matchings'] as List?;
    if (matchings == null || matchings.isEmpty) return null;
    final geom = decodePolyline(
      ((matchings.first as Map<String, dynamic>)['geometry'] ?? '') as String,
    );
    if (geom.isEmpty) return null;
    return geom.last;
  } catch (_) {
    return null; // never throw — GPS snapping is best-effort
  }
}

/// Haversine distance in meters.
double distanceMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

double _rad(double d) => d * math.pi / 180.0;
