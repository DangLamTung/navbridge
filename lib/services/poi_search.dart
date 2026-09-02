/// Point-of-interest search (Overpass/OSM) for quick "nearest X" during
/// navigation: gas, food, hotel, ATM, medical, parking.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A POI category shown as a quick button during navigation.
enum PoiType {
  fuel('fuel', 'Xăng', Icons.local_gas_station, 'amenity=fuel'),
  charging(
    'charging',
    'Sạc điện',
    Icons.ev_station,
    'amenity in charging_station',
  ),
  food(
    'food',
    'Ăn uống',
    Icons.restaurant,
    'amenity in restaurant,cafe,fast_food,food_court',
  ),
  cafeVong(
    'cafe_vong',
    'Cà phê võng',
    Icons.local_cafe,
    'amenity in cafe',
    'võng|vong', // hammock cafés: name often says "cà phê võng"
  ),
  hotel(
    'hotel',
    'Khách sạn',
    Icons.hotel,
    'tourism in hotel,motel,hostel,guest_house',
  ),
  atm('atm', 'ATM', Icons.local_atm, 'amenity in atm,bank'),
  hospital(
    'hospital',
    'Y tế',
    Icons.local_hospital,
    'amenity in hospital,clinic,pharmacy',
  ),
  parking('parking', 'Đỗ xe', Icons.local_parking, 'amenity=parking');

  const PoiType(
    this.key,
    this.label,
    this.icon,
    this.overpassFilter, [
    this.nameFilter,
  ]);

  final String key;
  final String label;
  final IconData icon;
  final String overpassFilter;

  /// Optional name regex to filter results (e.g. hammock cafés whose name
  /// contains "võng"). Null = no filter.
  final String? nameFilter;

  /// Google Places Nearby Search `type` for this category (null = no Google
  /// equivalent / don't search Google for it).
  String? get googleType => switch (this) {
    PoiType.fuel => 'gas_station',
    PoiType.charging => 'electric_vehicle_charging_station',
    PoiType.food => 'restaurant',
    PoiType.cafeVong => 'cafe',
    PoiType.hotel => 'lodging',
    PoiType.atm => 'atm',
    PoiType.hospital => 'hospital',
    PoiType.parking => 'parking',
  };
}

/// One search result.
class PoiResult {
  final String name;
  final double lat;
  final double lng;
  final PoiType type;

  /// Google user rating (0–5) when this came from Google Places; null for
  /// offline / Overpass / Vietmap results.
  final double? rating;

  /// Google review count (`user_ratings_total`); null for non-Google sources.
  final int? userRatingsTotal;

  /// Google place_id — used to de-duplicate corridor searches; null otherwise.
  final String? placeId;

  const PoiResult({
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
    this.rating,
    this.userRatingsTotal,
    this.placeId,
  });

  LatLng get pos => LatLng(lat, lng);
}

/// Brand color used to highlight a POI type (markers + cards).
Color poiColor(PoiType t) => switch (t) {
  PoiType.fuel => const Color(0xFFF4B400),
  PoiType.charging => const Color(0xFF00A651), // EV charging — green
  PoiType.food => const Color(0xFFEA4335),
  PoiType.cafeVong => const Color(0xFFB5651D), // hammock café — warm brown
  PoiType.hotel => const Color(0xFF1A73E8),
  PoiType.atm => const Color(0xFF9334E6),
  PoiType.hospital => const Color(0xFF34A853),
  PoiType.parking => const Color(0xFF5F6368),
};

const _mirrors = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.osm.ch/api/interpreter',
];

/// Small TTL cache so repeated quick searches don't re-hit slow Overpass
/// mirrors (the "Xăng" search used to take seconds on EVERY tap).
final _searchCache = <String, (List<PoiResult>, DateTime)>{};
const _searchCacheTtl = Duration(minutes: 4);

/// Find the nearest [type] POIs around [center] (Overpass `around` query).
/// All mirrors are queried in PARALLEL and the first valid answer wins (the
/// old sequential loop could take 3× the timeout). Results are sorted
/// nearest-first — Overpass returns `around` rows in ARBITRARY order, so the
/// old `out limit` could drop the closest station — and briefly cached.
Future<List<PoiResult>> searchPois(
  PoiType type,
  LatLng center, {
  double radius = 5000,
  int limit = 8,
}) async {
  final key =
      '${type.key}|${center.latitude.toStringAsFixed(3)},'
      '${center.longitude.toStringAsFixed(3)}|${radius.round()}';
  final hit = _searchCache[key];
  if (hit != null && DateTime.now().difference(hit.$2) < _searchCacheTtl) {
    return hit.$1;
  }
  // `nwr` covers nodes + ways + relations (many fuel/food POIs are ways);
  // `out <count> center;` — the count must come BEFORE `center` (the old
  // `out center 8;` form is rejected by the Overpass parser → search failed).
  // Fetch a LARGER set than [limit] so the nearest survive the truncation.
  final q =
      '[out:json][timeout:12];'
      '(nwr[${type.overpassFilter}]'
      '(around:${radius.round()},${center.latitude},${center.longitude}););'
      'out ${math.max(limit * 3, 40)} center;';
  final results = await _queryMirrors(type, q, center, limit);
  _searchCache[key] = (results, DateTime.now());
  return results;
}

/// Query every Overpass mirror at once; return the first valid (non-empty)
/// result. A slow or failed mirror no longer blocks the others.
Future<List<PoiResult>> _queryMirrors(
  PoiType type,
  String q,
  LatLng center,
  int limit,
) async {
  final completer = Completer<List<PoiResult>>();
  Object? firstError;
  Future<void> run(String mirror) async {
    try {
      final r = await _queryOne(type, mirror, q, center, limit);
      if (!completer.isCompleted) completer.complete(r);
    } catch (e) {
      firstError ??= e;
    }
  }

  for (final m in _mirrors) {
    unawaited(run(m));
  }
  return completer.future.timeout(
    const Duration(seconds: 13),
    onTimeout: () {
      if (firstError is Exception) throw firstError!;
      throw Exception('Không tìm thấy ${type.label} gần đây');
    },
  );
}

/// Query ONE mirror and return its [limit] nearest results (nearest-first so
/// the bigger `out <count>` truncation never drops the closest station).
Future<List<PoiResult>> _queryOne(
  PoiType type,
  String mirror,
  String q,
  LatLng center,
  int limit,
) async {
  final res = await http
      .post(
        Uri.parse(mirror),
        body: {'data': q},
        headers: const {'User-Agent': 'navbridge/1.0 (POI search)'},
      )
      .timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) throw Exception('Overpass HTTP ${res.statusCode}');
  final data = jsonDecode(utf8.decode(res.bodyBytes));
  final elements = (data['elements'] as List?) ?? const [];
  final out = <PoiResult>[];
  final nameRx = type.nameFilter == null
      ? null
      : RegExp(type.nameFilter!, caseSensitive: false);
  const Distance d = Distance();
  for (final e in elements) {
    if (e is! Map) continue;
    final tags = (e['tags'] as Map?) ?? const {};
    final lat = (e['lat'] ?? e['center']?['lat']) as num?;
    final lon = (e['lon'] ?? e['center']?['lon']) as num?;
    if (lat == null || lon == null) continue;
    // Unnamed stations are common → fall back to the category label.
    final name = (tags['name'] as String?)?.trim() ?? type.label;
    if (nameRx != null && !nameRx.hasMatch(name)) continue;
    out.add(
      PoiResult(
        name: name,
        lat: lat.toDouble(),
        lng: lon.toDouble(),
        type: type,
      ),
    );
  }
  out.sort(
    (a, b) => d
        .as(LengthUnit.Meter, center, a.pos)
        .compareTo(d.as(LengthUnit.Meter, center, b.pos)),
  );
  return out.take(limit).toList();
}

/// A scenic spot / viewpoint / mountain pass (đèo) found near the drive —
/// used by the AI to suggest beautiful stops along the route.
class ScenicSpot {
  final String name;
  final double lat;
  final double lng;
  final String kind; // 'điểm ngắm cảnh' | 'đèo' | 'đỉnh núi' | 'điểm đẹp'
  const ScenicSpot(this.name, this.lat, this.lng, this.kind);
}

/// Scenic spots + mountain passes near [center] via Overpass: viewpoints,
/// attractions, natural peaks and `highway=mountain_pass` (đèo). Best-effort
/// (empty on failure) — the AI uses these to suggest beautiful stops.
Future<List<ScenicSpot>> searchScenicSpots(
  LatLng center, {
  double radius = 20000,
  int limit = 8,
}) async {
  final q =
      '[out:json][timeout:20];'
      '(nwr[tourism in viewpoint,attraction,artwork,museum,castle]'
      '(around:${radius.round()},${center.latitude},${center.longitude});'
      'nwr[highway=mountain_pass]'
      '(around:${radius.round()},${center.latitude},${center.longitude});'
      'nwr[natural in peak,volcano]'
      '(around:${radius.round()},${center.latitude},${center.longitude}););'
      'out $limit center;';
  Object? last;
  for (final mirror in _mirrors) {
    try {
      final res = await http
          .post(
            Uri.parse(mirror),
            body: {'data': q},
            headers: const {'User-Agent': 'navbridge/1.0 (scenic search)'},
          )
          .timeout(const Duration(seconds: 18));
      if (res.statusCode != 200) continue;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final elements = (data['elements'] as List?) ?? const [];
      final out = <ScenicSpot>[];
      for (final e in elements) {
        if (e is! Map) continue;
        final tags = (e['tags'] as Map?) ?? const {};
        final lat = (e['lat'] ?? e['center']?['lat']) as num?;
        final lon = (e['lon'] ?? e['center']?['lon']) as num?;
        if (lat == null || lon == null) continue;
        final kind =
            tags['tourism'] == 'viewpoint' || tags['tourism'] == 'attraction'
            ? 'điểm ngắm cảnh'
            : tags['highway'] == 'mountain_pass'
            ? 'đèo'
            : (tags['natural'] == 'peak' || tags['natural'] == 'volcano')
            ? 'đỉnh núi'
            : 'điểm đẹp';
        out.add(
          ScenicSpot(
            (tags['name'] as String?)?.trim() ?? kind,
            lat.toDouble(),
            lon.toDouble(),
            kind,
          ),
        );
        if (out.length >= limit) break;
      }
      if (out.isNotEmpty) return out;
    } catch (e) {
      last = e;
    }
  }
  if (last is Exception) throw last;
  return const [];
}

/// Result of projecting a point onto the route: distance AHEAD along the
/// route (meters from the car, ≥ 0 = ahead, < 0 = behind) and the LATERAL
/// side of the road relative to travel direction (> 0 = LEFT, < 0 = RIGHT).
class RouteProjection {
  final double aheadMeters;
  final double lateralMeters;

  /// True when the point sits on the same side of the road the car is
  /// travelling (right-hand traffic → right side = no crossing / U-turn).
  bool get sameSide => lateralMeters <= 0;
  const RouteProjection({
    required this.aheadMeters,
    required this.lateralMeters,
  });
}

/// Project [p] onto the route polyline. [startIndex] is the car's snapped
/// vertex — its cumulative distance is where "ahead" begins, but the point is
/// projected onto the FULL route (not only from [startIndex]) so a point
/// behind the car lands on its real segment and reads as a NEGATIVE ahead.
/// Returns how far AHEAD along the route [p] is (its along-route distance
/// minus the car's) and its LATERAL offset (signed cross-track distance;
/// positive = left of travel, negative = right).
///
/// Used to rank POI search results: prefer places AHEAD on the route (the
/// driver is heading there) and on the SAME side of the road (crossing /
/// U-turning wastes time + energy).
RouteProjection projectOnRoute(
  List<LatLng> route,
  LatLng p, {
  int startIndex = 0,
}) {
  const d = Distance();
  if (route.length < 2) {
    return RouteProjection(aheadMeters: 0, lateralMeters: 0);
  }
  // Cumulative distance from the route START to the car's snapped vertex
  // (where "ahead" begins).
  double carCum = 0;
  for (var i = 0; i < startIndex && i + 1 < route.length; i++) {
    carCum += d.as(LengthUnit.Meter, route[i], route[i + 1]);
  }
  double bestOff = double.infinity;
  double bestAlong = 0; // cumulative at the projected point
  double bestLat = 0; // signed lateral (degrees-ish sign)
  // Walk the WHOLE route (not only from [startIndex]): a point BEHIND the car
  // must project onto its real (behind) segment and get a NEGATIVE ahead,
  // otherwise it clamps onto the car's segment with ahead≈0 and ranks as "at
  // the car" — which made "xăng gần nhất" point back the way we came.
  double cum = 0;
  for (var i = 0; i + 1 < route.length; i++) {
    final a = route[i];
    final b = route[i + 1];
    final seg = d.as(LengthUnit.Meter, a, b);
    // Planar projection onto segment a→b (fine at city scale).
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude, py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    // Allow slight backward extrapolation (t < 0) so points just BEHIND the
    // car still project to a negative ahead (they'd be a U-turn). Clamped to
    // a sane range so wildly-off points don't produce nonsense distances.
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(-1.0, 2.0);
    final proj = LatLng(ay + t * dy, ax + t * dx);
    final off = d.as(LengthUnit.Meter, proj, p);
    // Signed lateral: cross product of (b−a) × (p−a). Positive z → left of
    // travel direction (in standard lat/lng right-handed... with lon=x,
    // lat=y, north-up, a positive cross = LEFT). We only use the SIGN.
    final cross = dx * (py - ay) - dy * (px - ax);
    if (off < bestOff) {
      bestOff = off;
      bestAlong = cum + seg * t;
      bestLat = cross.isNaN || cross == 0 ? 0 : (cross > 0 ? 1 : -1);
    }
    cum += seg;
  }
  // ahead = distance from car (at carCum) to projected point.
  return RouteProjection(
    aheadMeters: bestAlong - carCum,
    lateralMeters: bestLat * bestOff,
  );
}

/// Rank POI search results for navigation: prefer places AHEAD along the
/// route (within [maxAheadMeters], ~10–20 km ahead) and on the SAME side of
/// the road as travel direction. Results behind the car or far off-route sink
/// to the bottom. Returns a re-sorted copy (does not mutate [results]).
List<PoiResult> rankPoisForRoute(
  List<PoiResult> results,
  List<LatLng> route, {
  int startIndex = 0,
  double maxAheadMeters = 15000,
}) {
  if (results.length < 2 || route.length < 2) return List.of(results);
  final scored = <(PoiResult, double)>[];
  for (final p in results) {
    final proj = projectOnRoute(route, p.pos, startIndex: startIndex);
    // Base: how far ahead (clamped so very-ahead items still rank near).
    final ahead = proj.aheadMeters.clamp(0.0, maxAheadMeters);
    // Penalise: BEHIND the car (any meaningful negative — was only < -500,
    // which let stations 0–500 m behind the car score 0 and top the list),
    // far beyond the window, or the wrong side of the road.
    var score = ahead;
    if (proj.aheadMeters < -50) score += 1e6; // behind → bottom
    if (proj.aheadMeters > maxAheadMeters) score += 1e5; // beyond window
    if (!proj.sameSide) score += 5000; // crossing/U-turn → deprioritise
    scored.add((p, score));
  }
  scored.sort((x, y) => x.$2.compareTo(y.$2));
  return [for (final (p, _) in scored) p];
}

/// How far (meters) the car is along [route] at [startIndex] — used to know
/// where "ahead" begins for route-aware POI ranking.
double routeCumulativeAt(List<LatLng> route, int startIndex) {
  const d = Distance();
  var c = 0.0;
  final n = startIndex.clamp(0, math.max(0, route.length - 1));
  for (var i = 0; i < n && i + 1 < route.length; i++) {
    c += d.as(LengthUnit.Meter, route[i], route[i + 1]);
  }
  return c;
}
