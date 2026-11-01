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
import 'package:navbridge/services/api_usage.dart' show ApiUsage;

import 'osrm.dart';
import 'route_traffic.dart';
import 'vietmap_config.dart';

/// Legacy Directions `mode=` for [profile].
///
/// A motorbike must not come through here (use
/// [fetchGoogleTwoWheelerRoutes]); it maps to `driving` only so a caller that
/// forgets still sends a valid mode instead of an invalid one.
String googleTravelMode(RouteProfile profile) => switch (profile) {
  RouteProfile.bicycle => 'bicycling',
  RouteProfile.walking => 'walking',
  // The Legacy Directions API has no lorry profile; trucks take `driving`
  // here, and the Routes API v2 call is what actually models them.
  RouteProfile.car || RouteProfile.motorbike || RouteProfile.truck => 'driving',
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
    // Live traffic. WITHOUT departure_time the response has no
    // duration_in_traffic at all and duration is the FREE-FLOW time, so a
    // ETA computed from it is a lie at rush hour. Measured on Q1 -> Thu Duc:
    // 3,250 s without, 3,454 s with (traffic_model=best_guess). This does not
    // change the billing SKU — `alternatives=true` already bills this as
    // Directions Advanced, so the traffic data is free.
    'departure_time=now',
    'traffic_model=best_guess',
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
  ApiUsage.note('directions');
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
      // Prefer the traffic-aware leg duration; fall back to free-flow for
      // walking/cycling (no traffic model) and for legs Google returns
      // without a duration_in_traffic.
      final legDur =
          (((leg['duration_in_traffic'] as Map?)?['value'] as num?) ??
                  ((leg['duration'] as Map?)?['value'] as num?) ??
                  0)
              .toDouble();
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
/// Routes API v2 `travelMode` for a profile.
///
/// Google models four road vehicles — `DRIVE` (ô tô), `TWO_WHEELER` (xe máy),
/// `TRUCK` (xe tải) and the human-powered pair — while the Legacy Directions
/// API only knows car/bicycle/walking. So every ROAD vehicle goes through v2,
/// which is also what carries the traffic intervals and the two-wheeler /
/// lorry restrictions (VN bans both from expressways).
String googleRoutesV2TravelMode(RouteProfile profile) => switch (profile) {
  RouteProfile.car => 'DRIVE',
  RouteProfile.motorbike => 'TWO_WHEELER',
  RouteProfile.truck => 'TRUCK',
  RouteProfile.bicycle => 'BICYCLE',
  RouteProfile.walking => 'WALK',
};

/// True when this profile is billed as Compute Routes **Enterprise**.
///
/// Google prices `TWO_WHEELER` and `TRUCK` one tier above `DRIVE`: Enterprise
/// ($15 / 1,000, 1,000 free per month) instead of Pro ($10 / 1,000, 5,000
/// free). The app's cost meter has to count the right SKU or it under-reports
/// spend by a third.
bool googleIsEnterpriseTier(RouteProfile profile) =>
    profile == RouteProfile.motorbike || profile == RouteProfile.truck;

/// Routes API v2 request body (pure → unit-tested).
Map<String, dynamic> googleComputeRoutesBody({
  required List<LatLng> points,
  RouteProfile profile = RouteProfile.motorbike,
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
}) {
  final truck = profile == RouteProfile.truck;
  // A lorry needs vehicle attributes before Google will route it; DIESEL is
  // the safe default for VN freight and only affects the eco/restriction
  // model, not the geometry.
  final vehicleInfo = truck
      ? <String, dynamic>{'emissionType': 'DIESEL'}
      : const <String, dynamic>{};
  return {
    'origin': _googleWaypoint(points.first),
    'destination': _googleWaypoint(points.last),
    if (points.length > 2)
      'intermediates': [
        for (final p in points.sublist(1, points.length - 1))
          _googleWaypoint(p),
      ],
    'travelMode': googleRoutesV2TravelMode(profile),
    // TRAFFIC_AWARE makes `duration` reflect live traffic (staticDuration
    // stays free-flow). The legacy Directions API has no two-wheeler or lorry
    // mode, so those ETAs had no traffic at all before this.
    'routingPreference': 'TRAFFIC_AWARE',
    'computeAlternativeRoutes': maxAlternatives > 1,
    // ⭐ Jam runs along the route (NORMAL / SLOW / TRAFFIC_JAM), so the line can
    // be coloured and the ETA can say how much of it is lost to traffic.
    // Billing: TRAFFIC_ON_POLYLINE is a Pro-tier extra, but TWO_WHEELER and
    // TRUCK are already billed at Enterprise, so it adds NOTHING there; for
    // DRIVE it is what makes the call a Pro request.
    'extraComputations': ['TRAFFIC_ON_POLYLINE'],
    'polylineQuality': 'HIGH_QUALITY',
    // Real-time model: Google requires a departure time to apply traffic, and
    // it must be in the future ("now" is rejected with INVALID_ARGUMENT — the
    // request is computed a couple of minutes ahead by the time it is answered).
    'departureTime': _googleDepartureTime(DateTime.now()),
    if (avoidHighway || avoidFerry || vehicleInfo.isNotEmpty)
      'routeModifiers': <String, dynamic>{
        if (avoidHighway) 'avoidHighways': true,
        if (avoidFerry) 'avoidFerries': true,
        if (vehicleInfo.isNotEmpty) 'vehicleInfo': vehicleInfo,
      },
    'languageCode': 'vi',
    'units': 'METRIC',
  };
}

/// Fetch a route via the Routes API `computeRoutes`, for ANY road vehicle:
/// `DRIVE` (ô tô), `TWO_WHEELER` (xe máy) or `TRUCK` (xe tải).
///
/// The Legacy Directions API has no two-wheeler and no lorry mode, and it
/// cannot return traffic intervals at all — so these three profiles come here.
/// Returns the same [OsrmRoute] shape the nav engine uses, now including
/// [OsrmRoute.traffic].
Future<List<OsrmRoute>> fetchGoogleRoutesV2(
  List<LatLng> points, {
  RouteProfile profile = RouteProfile.motorbike,
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
      profile: profile,
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
          // Only the fields the parser below actually reads. A '*' mask pulls
          // the whole route object (steps, tolls, advisories) over the wire
          // for nothing.
          'X-Goog-FieldMask':
              'routes.duration,routes.staticDuration,'
              'routes.distanceMeters,routes.polyline.encodedPolyline,'
              'routes.travelAdvisory.speedReadingIntervals,'
              'routes.legs.distanceMeters,routes.legs.duration,'
              'routes.legs.steps.distanceMeters,'
              'routes.legs.steps.staticDuration,'
              'routes.legs.steps.polyline.encodedPolyline,'
              'routes.legs.steps.startLocation,'
              'routes.legs.steps.navigationInstruction',
          'User-Agent': 'navbridge/1.0',
        },
        body: body,
      )
      .timeout(const Duration(seconds: 30));
  ApiUsage.note(googleIsEnterpriseTier(profile) ? 'routes_ent' : 'routes_pro');
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
        traffic: RouteTraffic.fromGoogle(
          r,
          geometry,
          seconds: _secondsFromDuration,
          measuredAt: DateTime.now(),
          forTime: _googleDepartureTimeValue(DateTime.now()),
        ),
      ),
    );
  }
  if (out.isEmpty) throw Exception('Không tìm thấy tuyến đường');
  return out;
}

/// Engine-agnostic live traffic for a route THIS app already planned.
///
/// The Google router carries its own intervals (see
/// `fetchGoogleTwoWheelerRoutes`), but the normal case is an OSRM / Vietmap /
/// offline route — those providers have no traffic at all. This asks Google the
/// same origin → destination question with `TRAFFIC_ON_POLYLINE` and re-anchors
/// the jam runs onto OUR geometry ([RouteTraffic.remap]), so the line can be
/// coloured whichever engine planned it.
///
/// COST: one Routes API request (Pro, or Enterprise for `TWO_WHEELER`). Call it
/// once per plan — never per fix. Returns null (no traffic, no error surfaced)
/// when there is no key, no network, or the API refuses; the route then draws in
/// one colour, which is exactly the pre-traffic behaviour.
Future<RouteTraffic?> fetchGoogleRouteTraffic({
  required LatLng from,
  required LatLng to,
  required List<LatLng> geometry,
  required double distanceMeters,
  RouteProfile profile = RouteProfile.motorbike,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty || geometry.length < 2) return null;
  final body = jsonEncode(<String, Object>{
    'origin': _googleWaypoint(from),
    'destination': _googleWaypoint(to),
    'travelMode': profile == RouteProfile.motorbike ? 'TWO_WHEELER' : 'DRIVE',
    'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
    'extraComputations': ['TRAFFIC_ON_POLYLINE'],
    'polylineQuality': 'HIGH_QUALITY',
    'departureTime': _googleDepartureTime(DateTime.now()),
    'languageCode': 'vi',
    'units': 'METRIC',
  });
  try {
    final res = await http
        .post(
          Uri.parse(
            'https://routes.googleapis.com/directions/v2:computeRoutes',
          ),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': key,
            'X-Goog-FieldMask':
                'routes.duration,routes.staticDuration,'
                'routes.distanceMeters,routes.polyline.encodedPolyline,'
                'routes.travelAdvisory.speedReadingIntervals',
            'User-Agent': 'navbridge/1.0',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    ApiUsage.note('routes_pro');
    if (res.statusCode != 200) {
      debugPrint('TRAFFIC: Google HTTP ${res.statusCode} — no live traffic');
      return null;
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final routes = (data['routes'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (routes.isEmpty) return null;
    final r = routes.first;
    final poly = ((r['polyline'] as Map?)?['encodedPolyline'] as String?) ?? '';
    final gGeo = poly.isEmpty ? const <LatLng>[] : decodePolyline(poly);
    final base = RouteTraffic.fromGoogle(
      r,
      gGeo,
      seconds: _secondsFromDuration,
      measuredAt: DateTime.now(),
      forTime: _googleDepartureTimeValue(DateTime.now()),
    );
    if (base == null) return null;
    if (gGeo.isEmpty) return base;
    final spans = RouteTraffic.remap(
      base.spans,
      gGeo,
      geometry,
      fromMeters: ((r['distanceMeters'] as num?) ?? 0).toDouble(),
      toMeters: distanceMeters,
    );
    return RouteTraffic(
      live: base.live,
      freeFlow: base.freeFlow,
      spans: spans,
      measuredAt: base.measuredAt,
      forTime: base.forTime,
    );
  } catch (e) {
    debugPrint('TRAFFIC: could not read traffic — $e');
    return null;
  }
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

/// `departureTime` for a traffic-aware request, RFC 3339 in UTC.
///
/// Google rejects "now" and any past timestamp ("Timestamp must be set to a
/// future time"), so the request is stamped a couple of minutes ahead — the
/// call itself takes a moment, and traffic at t+2min is the traffic the driver
/// is about to meet.
DateTime _googleDepartureTimeValue(DateTime now) =>
    now.toUtc().add(const Duration(minutes: 2)).toLocal();

String _googleDepartureTime(DateTime now) {
  final t = now.toUtc().add(const Duration(minutes: 2));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
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
