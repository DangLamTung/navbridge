/// Overpass (OSM) road lookup — resolves the current road's type and speed
/// limit from OSM tags.
///
/// OSM has full `highway=` + `name` coverage for Vietnam, but `maxspeed` is
/// rarely tagged in cities, so a Vietnam statutory default per road class is
/// applied when the tag is missing.
///
/// Endpoints are tried in order with a client-side cache so we never hammer
/// the free service (Overpass limit ~1 req/s).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'osrm.dart' show distanceMeters;

/// Road info resolved from OSM tags at a position.
class RoadInfo {
  final String name; // road name (may be empty in OSM)
  final String highway; // OSM highway= value (primary, residential, …)
  final String? maxspeed; // tagged maxspeed if any (e.g. "50", "50 km/h")
  final String label; // Vietnamese label for the road class
  final int speedLimit; // effective km/h limit (tagged or VN default)

  RoadInfo({
    required this.name,
    required this.highway,
    this.maxspeed,
    required this.label,
    required this.speedLimit,
  });
}

/// Overpass mirrors — tried in order until one answers.
const List<String> _endpoints = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.osm.ch/api/interpreter',
];

const String _ua = 'navbridge/1.0 (BLE portable navigation; road info)';

/// Vietnamese label + statutory default limit (km/h) per OSM/GraphHopper
/// highway class value. Used when the way has no `maxspeed` tag.
(String, int) classInfo(String highway) => switch (highway) {
  'motorway' => ('Cao tốc', 120),
  'motorway_link' => ('Cao tốc', 100),
  'trunk' => ('Quốc lộ', 90),
  'trunk_link' => ('Quốc lộ', 80),
  'primary' => ('Quốc lộ', 80),
  'primary_link' => ('Quốc lộ', 60),
  'secondary' => ('Tỉnh lộ', 60),
  'secondary_link' => ('Tỉnh lộ', 50),
  'tertiary' => ('Đường huyện', 50),
  'tertiary_link' => ('Đường huyện', 50),
  'unclassified' => ('Đường làng', 50),
  'residential' => ('Đường dân sinh', 50),
  'living_street' => ('Đường phố', 20),
  'service' => ('Đường nội bộ', 30),
  'pedestrian' => ('Phố đi bộ', 10),
  'footway' => ('Lối đi bộ', 10),
  'cycleway' => ('Đường xe đạp', 20),
  _ => ('Đường', 50),
};

/// Parse a raw OSM maxspeed tag into km/h: "50", "50 km/h", "30 mph",
/// "15 knots", "none", … Unknown/non-numeric values return [fallback].
int parseMaxspeed(String? raw, int fallback) {
  if (raw == null || raw.isEmpty) return fallback;
  final t = raw.toLowerCase().trim();
  if (t == 'none' || t == 'signals' || t == 'variable' || t == 'walk') {
    return fallback;
  }
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(t);
  if (m == null) return fallback;
  final v = double.parse(m.group(1)!);
  // OSM stores imperial units verbatim — convert to km/h (the chip is km/h).
  if (t.contains('mph')) return (v * 1.609344).round();
  if (t.contains('knot')) return (v * 1.852).round();
  return v.round();
}

/// Simple client-side cache: last result + where we queried it.
class _Cache {
  RoadInfo? last;
  LatLng? at;
}

final _Cache _cache = _Cache();

/// Fetch the road under [pos]. Reuses the cached result while the fix is
/// within ~25 m of the last query (a road is ~10 m wide, so that means we are
/// still on the same road). Returns the last known value on failure.
Future<RoadInfo?> fetchRoadInfo(LatLng pos) async {
  final cached = _cache.last;
  if (cached != null && _cache.at != null) {
    if (distanceMeters(pos, _cache.at!) < 25) return cached;
  }

  final query =
      '[out:json][timeout:10];'
      'way(around:15,${pos.latitude},${pos.longitude})[highway];'
      'out tags center;';

  http.Response? res;
  for (final ep in _endpoints) {
    try {
      res = await http
          .post(
            Uri.parse(ep),
            body: {'data': query},
            headers: {'User-Agent': _ua},
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) break;
    } catch (_) {
      // try the next mirror
    }
  }
  if (res == null || res.statusCode != 200) return cached;

  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final elements = (data['elements'] as List? ?? [])
      .cast<Map<String, dynamic>>();
  if (elements.isEmpty) return cached;

  // Prefer drivable ways; fall back to everything (pedestrian streets etc.).
  final drivable = elements.where((e) {
    final hw =
        ((e['tags'] as Map<String, dynamic>? ?? {})['highway'] ?? '') as String;
    return _isDrivable(hw);
  }).toList();
  final pool = drivable.isNotEmpty ? drivable : elements;

  Map<String, dynamic>? best;
  var bestD = double.infinity;
  for (final e in pool) {
    final c = e['center'];
    if (c is! Map || c['lat'] == null || c['lon'] == null) continue;
    final d = distanceMeters(
      pos,
      LatLng((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble()),
    );
    if (d < bestD) {
      bestD = d;
      best = e;
    }
  }
  if (best == null) return cached;

  final tags = (best['tags'] as Map<String, dynamic>? ?? {});
  final highway = (tags['highway'] ?? '') as String;
  final (label, fallback) = classInfo(highway);
  final info = RoadInfo(
    name: (tags['name'] ?? '') as String,
    highway: highway,
    maxspeed: tags['maxspeed'] as String?,
    label: label,
    speedLimit: parseMaxspeed(tags['maxspeed'] as String?, fallback),
  );
  _cache.last = info;
  _cache.at = pos;
  return info;
}

bool _isDrivable(String hw) => !const {
  'footway',
  'path',
  'steps',
  'cycleway',
  'bridleway',
  'track',
  'construction',
}.contains(hw);
