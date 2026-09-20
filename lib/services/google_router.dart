/// Google routing client — the "Google" data source.
///
/// Two endpoints, because Google splits them:
///   • [fetchGoogleRoutes] — **Directions API (Legacy)** for car / bicycle /
///     walking (`mode=driving|bicycling|walking`). Honours
///     `avoid=highways|ferries`.
///   • [fetchGoogleTwoWheelerRoutes] — **Routes API v2** `computeRoutes` for
///     motorbikes (`travelMode: TWO_WHEELER`), the only Google mode that models
///     two-wheelers — which VN law bans from expressways. Honours
///     `routeModifiers.avoidHighways/avoidFerries`, which Google scopes to
///     DRIVE **and TWO_WHEELER**.
///
/// Both need billing + the relevant API enabled on the single
/// `VietmapConfig.googlePlacesKey`, and both return the [OsrmRoute] shape the
/// nav engine consumes, so they drop straight into `fetchAnyRoutes`. Which
/// provider runs when (and what it can honour) lives in `route_providers.dart`.
///
/// [googleDirectionsUrl] / [googleComputeRoutesBody] are PURE builders so the
/// request contract is unit-testable without the network — the reason the
/// avoid-flags and travel mode can be asserted at all.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/route_profile.dart';

import 'osrm.dart';
import 'vietmap_config.dart';

/// Legacy Directions `mode=` for [profile].
///
/// A motorbike must not come through here (use
/// [fetchGoogleTwoWheelerRoutes]); it maps to `driving` only so a caller that
/// forgets still sends a valid mode instead of an invalid one.
String googleTravelMode(RouteProfile profile) => switch (profile) {
  RouteProfile.bicycle => 'bicycling',
  RouteProfile.walking => 'walking',
  RouteProfile.car || RouteProfile.motorbike => 'driving',
};

/// Legacy Directions request URL (pure → unit-tested).
///
/// `avoid=` is a pipe-separated list and, per Google's docs, BIASES the result
/// toward routes without the feature rather than forbidding it. Walking has no
/// highways and the Legacy API ignores `avoid` there, so nothing is appended
/// for walking and the request stays unambiguously valid.
String googleDirectionsUrl({
  required List<LatLng> points,
  required String key,
  RouteProfile profile = RouteProfile.car,
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
}) {
  final origin = points.first;
  final dest = points.last;
  final via = points.length > 2
      ? points.sublist(1, points.length - 1)
      : const <LatLng>[];
  final walk = profile == RouteProfile.walking;
  final avoid = [
    if (avoidHighway && !walk) 'highways',
    if (avoidFerry && !walk) 'ferries',
  ];
  final parts = [
    'origin=${origin.latitude},${origin.longitude}',
    'destination=${dest.latitude},${dest.longitude}',
    'mode=${googleTravelMode(profile)}',
    'language=vi',
    'alternatives=${maxAlternatives > 1}',
    if (avoid.isNotEmpty) 'avoid=${avoid.join('|')}',
    if (via.isNotEmpty)
      'waypoints=${via.map((w) => '${w.latitude},${w.longitude}').join('|')}',
    'key=$key',
  ];
  return 'https://maps.googleapis.com/maps/api/directions/json'
      '?${parts.join('&')}';
}

/// Fetch up to [maxAlternatives] Google routes through [points] (2+ waypoints,
/// origin → … → destination) via the Directions API (Legacy), honouring the
/// profile's travel mode and the avoid toggles. Converts each Google route to
/// [OsrmRoute] (geometry decoded from the overview polyline, steps from the leg
/// steps, stopCumulative from leg distances). Throws a descriptive exception
/// on failure (missing key / HTTP / API status) — `fetchAnyRoutes` turns that
/// into a visible fall-through notice plus the next provider in the chain.
Future<List<OsrmRoute>> fetchGoogleRoutes(
  List<LatLng> points, {
  int maxAlternatives = 3,
  RouteProfile profile = RouteProfile.car,
  bool avoidHighway = false,
  bool avoidFerry = false,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) throw Exception('Chưa có khoá Google Maps');
  if (points.length < 2) {
    throw Exception('Cần ít nhất điểm đi và điểm đến');
  }

  final url = googleDirectionsUrl(
    points: points,
    key: key,
    profile: profile,
    maxAlternatives: maxAlternatives,
    avoidHighway: avoidHighway,
    avoidFerry: avoidFerry,
  );

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
  // Google REQUIRES these to be surfaced to the user (bicycling/walking "no
  // dedicated path" caveats, road closures, …). Logged for now — a SnackBar on
  // every route would be noise; raise via `announceApiNotice` if they matter.
  for (final r in routes.take(1)) {
    for (final w in (r['warnings'] as List? ?? const [])) {
      debugPrint('GOOGLE: warning: $w');
    }
  }
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

/// Routes API v2 `computeRoutes` request body (pure → unit-tested).
///
/// `routeModifiers` is only attached when a toggle is on: Google documents
/// `avoidHighways` / `avoidFerries` as applying to `DRIVE` and `TWO_WHEELER`,
/// which is exactly the two profiles that reach this endpoint (a motorbike is
/// already barred from VN expressways by `TWO_WHEELER` itself).
Map<String, dynamic> googleComputeRoutesBody({
  required List<LatLng> points,
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
}) {
  return {
    'origin': _googleWaypoint(points.first),
    'destination': _googleWaypoint(points.last),
    if (points.length > 2)
      'intermediates': [
        for (final p in points.sublist(1, points.length - 1))
          _googleWaypoint(p),
      ],
    'travelMode': 'TWO_WHEELER',
    'computeAlternativeRoutes': maxAlternatives > 1,
    if (avoidHighway || avoidFerry)
      'routeModifiers': {
        if (avoidHighway) 'avoidHighways': true,
        if (avoidFerry) 'avoidFerries': true,
      },
    'languageCode': 'vi',
    'units': 'METRIC',
  };
}

/// Fetch a motorbike route via the Routes API `computeRoutes` with
/// `travelMode: TWO_WHEELER` (the Legacy Directions API has no motorbike
/// mode, so this is the only way to get a real Google two-wheeler route —
/// two-wheelers are banned from VN expressways, which this mode accounts
/// for). Returns the same [OsrmRoute] shape the nav engine uses.
Future<List<OsrmRoute>> fetchGoogleTwoWheelerRoutes(
  List<LatLng> points, {
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) throw Exception('Chưa có khoá Google Maps');
  if (points.length < 2) throw Exception('Cần ít nhất điểm đi và điểm đến');

  final body = jsonEncode(
    googleComputeRoutesBody(
      points: points,
      maxAlternatives: maxAlternatives,
      avoidHighway: avoidHighway,
      avoidFerry: avoidFerry,
    ),
  );

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
  final routes = (data['routes'] as List? ?? const [])
      .cast<Map<String, dynamic>>();

  final out = <OsrmRoute>[];
  for (final r in routes.take(maxAlternatives)) {
    final polyline =
        ((r['polyline'] as Map?)?['encodedPolyline'] as String?) ?? '';
    final geometry = polyline.isEmpty
        ? const <LatLng>[]
        : decodePolyline(polyline);
    final durationS = _secondsFromDuration((r['duration'] as String?) ?? '');
    final distanceM = ((r['distanceMeters'] as num?) ?? 0).toDouble();

    final steps = <OsrmStep>[];
    final stopCum = <double>[];
    var cum = 0.0;
    final legs = (r['legs'] as List? ?? const []).cast<Map<String, dynamic>>();
    for (final leg in legs) {
      cum += ((leg['distanceMeters'] as num?) ?? 0).toDouble();
      stopCum.add(cum);
      final legSteps = (leg['steps'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
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
  'ROUNDABOUT_STRAIGHT' => ('roundabout', null),
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
