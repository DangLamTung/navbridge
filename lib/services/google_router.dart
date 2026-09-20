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

/// Fetch a motorbike route via the Routes API `computeRoutes` with
/// `travelMode: TWO_WHEELER` (the Legacy Directions API has no motorbike
/// mode, so this is the only way to get a real Google two-wheeler route —
/// two-wheelers are banned from VN expressways, which this mode accounts
/// for). Returns the same [OsrmRoute] shape the nav engine uses.
Future<List<OsrmRoute>> fetchGoogleTwoWheelerRoutes(
  List<LatLng> points, {
  int maxAlternatives = 3,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) throw Exception('Chưa có khoá Google Maps');
  if (points.length < 2) throw Exception('Cần ít nhất điểm đi và điểm đến');

  final body = jsonEncode({
    'origin': _googleWaypoint(points.first),
    'destination': _googleWaypoint(points.last),
    if (points.length > 2)
      'intermediates': [
        for (final p in points.sublist(1, points.length - 1))
          _googleWaypoint(p),
      ],
    'travelMode': 'TWO_WHEELER',
    'computeAlternativeRoutes': maxAlternatives > 1,
    'languageCode': 'vi',
    'units': 'METRIC',
  });

  final res = await http
      .post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask': '*',
          'User-Agent': 'navbridge/1.0',
        },
        body: body,
      )
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Google Routes HTTP ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final routes =
      (data['routes'] as List? ?? const []).cast<Map<String, dynamic>>();

  final out = <OsrmRoute>[];
  for (final r in routes.take(maxAlternatives)) {
    final polyline =
        ((r['polyline'] as Map?)?['encodedPolyline'] as String?) ?? '';
    final geometry =
        polyline.isEmpty ? const <LatLng>[] : decodePolyline(polyline);
    final durationS = _secondsFromDuration((r['duration'] as String?) ?? '');
    final distanceM = ((r['distanceMeters'] as num?) ?? 0).toDouble();

    final steps = <OsrmStep>[];
    final stopCum = <double>[];
    var cum = 0.0;
    final legs =
        (r['legs'] as List? ?? const []).cast<Map<String, dynamic>>();
    for (final leg in legs) {
      cum += ((leg['distanceMeters'] as num?) ?? 0).toDouble();
      stopCum.add(cum);
      final legSteps =
          (leg['steps'] as List? ?? const []).cast<Map<String, dynamic>>();
      for (final s in legSteps) {
        final nav = (s['navigationInstruction'] as Map?) ?? const {};
        final sPoly =
            ((s['polyline'] as Map?)?['encodedPolyline'] as String?) ?? '';
        final sPts = sPoly.isEmpty ? const <LatLng>[] : decodePolyline(sPoly);
        final start = (s['startLocation'] as Map?)?['latLng'] as Map?;
        final slat = (start?['latitude'] as num?)?.toDouble();
        final slng = (start?['longitude'] as num?)?.toDouble();
        final maneuver = _fromGoogleManeuver(
          (nav['maneuver'] as String?) ?? '',
        );
        steps.add(
          OsrmStep(
            name: _googleInstructionText(nav['instructions'] as String?),
            distance: ((s['distanceMeters'] as num?) ?? 0).toDouble(),
            duration: _secondsFromDuration(
              (s['staticDuration'] ?? s['duration'] ?? '') as String,
            ).toDouble(),
            type: maneuver.$1,
            modifier: maneuver.$2,
            maneuver: sPts.isNotEmpty
                ? sPts.first
                : (slat != null && slng != null
                      ? LatLng(slat, slng)
                      : const LatLng(0, 0)),
          ),
        );
      }
    }

    out.add(
      OsrmRoute(
        distance: distanceM,
        duration: durationS.toDouble(),
        geometry: geometry,
        steps: steps,
        stopCumulative: points.length > 2 ? stopCum : const [],
      ),
    );
  }
  if (out.isEmpty) throw Exception('Không tìm thấy tuyến đường');
  return out;
}

Map<String, dynamic> _googleWaypoint(LatLng p) => {
  'location': {
    'latLng': {'latitude': p.latitude, 'longitude': p.longitude},
  },
};

/// Routes API durations are strings like "165s" → 165 seconds.
int _secondsFromDuration(String s) {
  final m = RegExp(r'^(\d+)s$').firstMatch(s.trim());
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// Translate a Routes API maneuver into the OSRM-style (type, modifier) pair
/// the nav engine's [iconForManeuver] understands.
(String, String?) _fromGoogleManeuver(String m) => switch (m) {
  'DEPART' => ('depart', null),
  'ARRIVE' => ('arrive', null),
  'TURN_LEFT' => ('turn', 'left'),
  'TURN_RIGHT' => ('turn', 'right'),
  'TURN_SHARP_LEFT' => ('turn', 'sharp left'),
  'TURN_SHARP_RIGHT' => ('turn', 'sharp right'),
  'TURN_SLIGHT_LEFT' => ('turn', 'slight left'),
  'TURN_SLIGHT_RIGHT' => ('turn', 'slight right'),
  'UTURN_LEFT' => ('uturn', 'left'),
  'UTURN_RIGHT' => ('uturn', 'right'),
  'MERGE' => ('merge', null),
  'ROUNDABOUT_LEFT' ||
  'ROUNDABOUT_RIGHT' ||
  'ROUNDABOUT_STRAIGHT' =>
    ('roundabout', null),
  'FORK_LEFT' => ('fork', 'left'),
  'FORK_RIGHT' => ('fork', 'right'),
  'RAMP_LEFT' || 'ON_RAMP_LEFT' => ('on ramp', 'left'),
  'RAMP_RIGHT' || 'ON_RAMP_RIGHT' => ('on ramp', 'right'),
  'KEEP_LEFT' => ('continue', 'left'),
  'KEEP_RIGHT' => ('continue', 'right'),
  'NAME_CHANGE' => ('new name', null),
  _ => ('continue', null),
};

/// Strip HTML from a Routes API instruction and collapse whitespace.
String _googleInstructionText(String? html) {
  if (html == null || html.isEmpty) return 'tiếp tục';
  final s = html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? 'tiếp tục' : s;
}
