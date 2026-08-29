/// Google Places API helpers — POI search (Nearby Search) for the quick
/// navigation categories (gas, food, ATM, …). Used when GOOGLE_PLACES_KEY is
/// configured; the app falls back to Overpass / offline / Vietmap otherwise.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'poi_search.dart';
import 'vietmap_config.dart';

/// Google Places Nearby Search for [type] around a CORRIDOR of [centers]
/// (the car + points ahead on the route, each searched with a [radius]-meter
/// circle) — i.e. a ±15 km corridor along the driving path instead of one
/// giant circle around the car (so the results are places the driver is
/// actually heading toward).
///
/// Behaviour by category:
///  * fuel        → `rankby=distance` nearest pass around the car, then
///    corridor passes ahead (so the nearest stations show first, but the list
///    still covers the route ahead).
///  * everything  → prominence passes along the corridor (Google's
///    "well-known / well-rated" ranking, ideal for picking the highest-rated
///    restaurant).
///
/// Results are de-duplicated by place_id and carry Google rating data
/// (rating + user_ratings_total + place_id) so callers can show restaurants
/// by highest rating and gas by nearest. Returns empty (never throws) when
/// there is no Google key or on any failure — the caller keeps its other
/// sources.
Future<List<PoiResult>> googlePoiSearch(
  PoiType type,
  List<LatLng> centers, {
  double radius = 15000,
  int limit = 30,
}) async {
  if (VietmapConfig.googlePlacesKey.isEmpty) return const [];
  if (centers.isEmpty) return const [];
  final googleType = type.googleType;
  if (googleType == null) return const [];
  final seen = <String>{};
  final out = <PoiResult>[];

  void add(Map r) {
    final loc = ((r['geometry'] as Map?)?['location'] as Map?) ?? const {};
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    final name = (r['name'] as String?)?.trim() ?? '';
    if (lat == null || lng == null || name.isEmpty) return;
    final pid = (r['place_id'] as String?) ?? '';
    if (pid.isNotEmpty && !seen.add(pid)) return;
    out.add(
      PoiResult(
        name: name,
        lat: lat,
        lng: lng,
        type: type,
        rating: (r['rating'] as num?)?.toDouble(),
        userRatingsTotal: (r['user_ratings_total'] as num?)?.toInt(),
        placeId: pid,
      ),
    );
  }

  Future<void> query(LatLng c, {bool rankByDistance = false}) async {
    try {
      final params = <String, String>{
        'location': '${c.latitude},${c.longitude}',
        'type': googleType,
        'language': 'vi',
        'key': VietmapConfig.googlePlacesKey,
      };
      if (rankByDistance) {
        // Nearest-first around this point (Google forbids `radius` together
        // with rankby=distance; it returns ~20 nearest).
        params['rankby'] = 'distance';
      } else {
        params['radius'] = radius.round().toString();
      }
      final res = await http
          .get(
            Uri.https(
              'maps.googleapis.com',
              '/maps/api/place/nearbysearch/json',
              params,
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map?;
      for (final r in ((data?['results'] as List?) ?? const [])) {
        if (r is! Map) continue;
        add(r);
        if (out.length >= limit) return;
      }
    } catch (_) {
      // Best-effort: one failed center shouldn't kill the rest.
    }
  }

  // Nearest pass around the car (fuel) / first corridor center (others use
  // the prominence pass below — the default — for well-rated places).
  await query(centers.first, rankByDistance: type == PoiType.fuel);
  // Corridor passes ahead on the route.
  for (final c in centers.skip(1)) {
    if (out.length >= limit) break;
    await query(c);
  }
  return out;
}
