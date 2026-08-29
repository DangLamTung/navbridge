/// Google Maps Directions API client — driving route(s) with Google's
/// traffic-aware ETA. Used when the user picks "Google" as the data source
/// (search already uses Google Places; this makes ROUTING use Google too).
///
/// Requires the Directions API enabled on the key (GOOGLE_PLACES_KEY) +
/// billing. Returns routes in the same [OsrmRoute] shape the nav engine uses,
/// so Google fits right into `fetchAnyRoutes` (falls back to OSRM on failure).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'osrm.dart';
import 'vietmap_config.dart';

/// Fetch up to [maxAlternatives] Google driving routes through [points]
/// (2+ waypoints, origin → … → destination). Converts each Google route to
/// [OsrmRoute] (geometry decoded from overview polyline, steps from leg
/// steps, stopCumulative from leg distances). Throws a descriptive exception
/// on failure (missing key / HTTP / API status).
Future<List<OsrmRoute>> fetchGoogleRoutes(
  List<LatLng> points, {
  int maxAlternatives = 3,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) throw Exception('Chưa có khoá Google Maps');
  if (points.length < 2) {
    throw Exception('Cần ít nhất điểm đi và điểm đến');
  }
  final origin = points.first;
  final dest = points.last;
  final via = points.length > 2
      ? points.sublist(1, points.length - 1)
      : <LatLng>[];

  var url =
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${dest.latitude},${dest.longitude}'
      '&mode=driving'
      '&language=vi'
      '&alternatives=${maxAlternatives > 1}'
      '&key=$key';
  if (via.isNotEmpty) {
    url +=
        '&waypoints=${via.map((w) => '${w.latitude},${w.longitude}').join('|')}';
  }

  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Google Directions HTTP ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final status = (data['status'] ?? '') as String;
  if (status != 'OK') {
    throw Exception(
      'Google Directions: $status ${(data['error_message'] ?? '') as String}',
    );
  }

  final routes = (data['routes'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <OsrmRoute>[];
  for (final r in routes.take(maxAlternatives)) {
    final legs = (r['legs'] as List? ?? const []).cast<Map<String, dynamic>>();
    final overview =
        ((r['overview_polyline'] as Map?)?['points'] as String?) ?? '';
    final geometry = overview.isEmpty
        ? const <LatLng>[]
        : decodePolyline(overview);
    double dist = 0, dur = 0;
    final steps = <OsrmStep>[];
    final stopCum = <double>[];
    for (var li = 0; li < legs.length; li++) {
      final leg = legs[li];
      final legDist =
          ((leg['distance'] as Map?)?['value'] as num?)?.toDouble() ?? 0;
      final legDur =
          ((leg['duration'] as Map?)?['value'] as num?)?.toDouble() ?? 0;
      dist += legDist;
      dur += legDur;
      stopCum.add(dist);
      final legSteps = (leg['steps'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      for (final s in legSteps) {
        final sp = ((s['polyline'] as Map?)?['points'] as String?) ?? '';
        final pts = sp.isEmpty ? const <LatLng>[] : decodePolyline(sp);
        final man = (s['maneuver'] as Map?) ?? const {};
        final startLoc = (s['start_location'] as Map?) ?? const {};
        final slat = (startLoc['lat'] as num?)?.toDouble();
        final slng = (startLoc['lng'] as num?)?.toDouble();
        final name = ((s['name'] as String?) ?? '').trim();
        final sDist =
            ((s['distance'] as Map?)?['value'] as num?)?.toDouble() ?? 0;
        final sDur =
            ((s['duration'] as Map?)?['value'] as num?)?.toDouble() ?? 0;
        steps.add(
          OsrmStep(
            name: name.isEmpty ? 'tiếp tục' : name,
            distance: sDist,
            duration: sDur,
            type: ((man['type'] as String?) ?? 'continue'),
            modifier: ((man['modifier'] as String?) ?? 'straight'),
            maneuver: pts.isNotEmpty
                ? pts.first
                : (slat != null && slng != null
                      ? LatLng(slat, slng)
                      : const LatLng(0, 0)),
          ),
        );
      }
    }
    out.add(
      OsrmRoute(
        distance: dist,
        duration: dur,
        geometry: geometry,
        steps: steps,
        stopCumulative: points.length > 2 ? stopCum : const [],
      ),
    );
  }
  return out;
}
