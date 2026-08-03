/// OSRM routing client — fetch a driving route with turn-by-turn steps.
///
/// Free public server (worldwide OSM data). For better Vietnam routing you can
/// point `baseUrl` at a self-hosted OSRM built from a Vietnam PBF
/// (see ../osrm/build.sh in the Eink workspace).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const String osrmPublic = 'https://router.project-osrm.org';

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

/// A full OSRM route.
class OsrmRoute {
  final double distance; // meters
  final double duration; // seconds
  final List<LatLng> geometry; // full route polyline (decoded)
  final List<OsrmStep> steps;
  final List<double> stopCumulative; // meters along the polyline at each stop

  OsrmRoute({
    required this.distance,
    required this.duration,
    required this.geometry,
    required this.steps,
    this.stopCumulative = const [],
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
Future<OsrmRoute> fetchOsrmRoute(
  List<LatLng> points, {
  String? baseUrl,
  bool steps = true,
  String profile = 'driving',
}) async {
  if (points.length < 2) {
    throw Exception('Cần ít nhất 2 điểm để định tuyến');
  }
  final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
  final url = '${baseUrl ?? osrmPublic}/route/v1/$profile/'
      '$coords?overview=full&geometries=polyline&steps=$steps';
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    throw Exception('OSRM HTTP ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes));
  final routes = data['routes'] as List?;
  if (routes == null || routes.isEmpty) {
    throw Exception('Không tìm thấy tuyến đường');
  }
  final r = routes.first as Map<String, dynamic>;

  final stepList = <OsrmStep>[];
  final stopCum = <double>[];
  var cum = 0.0;
  final legs = (r['legs'] as List? ?? []).cast<Map<String, dynamic>>();
  for (final leg in legs) {
    for (final s
        in (leg['steps'] as List? ?? []).cast<Map<String, dynamic>>()) {
      final m = (s['maneuver'] as Map<String, dynamic>? ?? {});
      final loc = (m['location'] as List?)?.cast<num>() ?? [];
      stepList.add(OsrmStep(
        name: (s['name'] ?? '') as String,
        distance: ((s['distance'] ?? 0) as num).toDouble(),
        duration: ((s['duration'] ?? 0) as num).toDouble(),
        type: (m['type'] ?? '') as String,
        modifier: m['modifier'] as String?,
        maneuver: loc.length >= 2
            ? LatLng(loc[1].toDouble(), loc[0].toDouble())
            : points.last,
      ));
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

/// Haversine distance in meters.
double distanceMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

double _rad(double d) => d * math.pi / 180.0;
