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

/// Vietnamese statutory default limit (km/h) per highway class per vehicle.
/// OSM rarely tags `maxspeed` in VN cities, so this fills the gap. The car
/// table mirrors [classInfo]; motorbike / truck are lower (motorbikes are
/// prohibited on motorways — capped rather than 0 so the chip never shows an
/// empty limit).
int statutoryLimit(String highway, {String vehicle = 'car'}) {
  const car = {
    'motorway': 120,
    'motorway_link': 100,
    'trunk': 90,
    'trunk_link': 80,
    'primary': 80,
    'primary_link': 60,
    'secondary': 60,
    'secondary_link': 50,
    'tertiary': 50,
    'tertiary_link': 50,
    // Urban streets without a median: posted 40 km/h (QCVN 41) — 50 was
    // too high and made the limit read wrong on city roads.
    'unclassified': 40,
    'residential': 40,
    'living_street': 20,
    'service': 30,
    'pedestrian': 10,
    'footway': 10,
    'cycleway': 20,
  };
  const motorbike = {
    'motorway': 80,
    'motorway_link': 60,
    'trunk': 80,
    'trunk_link': 60,
    'primary': 70,
    'primary_link': 50,
    'secondary': 60,
    'secondary_link': 50,
    'tertiary': 60,
    'tertiary_link': 50,
    'unclassified': 40,
    'residential': 40,
    'living_street': 20,
    'service': 30,
    'pedestrian': 10,
    'footway': 10,
    'cycleway': 20,
  };
  const truck = {
    'motorway': 80,
    'motorway_link': 70,
    'trunk': 70,
    'trunk_link': 60,
    'primary': 60,
    'primary_link': 50,
    'secondary': 50,
    'secondary_link': 40,
    'tertiary': 50,
    'tertiary_link': 40,
    'unclassified': 40,
    'residential': 40,
    'living_street': 20,
    'service': 30,
    'pedestrian': 10,
    'footway': 10,
    'cycleway': 20,
  };
  final table = switch (vehicle) {
    'motorbike' => motorbike,
    'truck' => truck,
    _ => car,
  };
  return table[highway] ?? 50;
}

/// Parse a raw OSM maxspeed tag into km/h: "50", "50 km/h", "30 mph",
/// "15 knots", "none", … Unknown/non-numeric values return [fallback].
///
/// Quality guards:
///  * multi-value / conditional tags ("50;30", "50-60", "30 @ (06:00-22:00)")
///    → take the FIRST numeric value (the base posted limit).
///  * absurd values (typos like "999", or a garbage bit-pattern from a
///    mis-decoded GraphHopper edge) → return [fallback], never a nonsense
///    limit. This is what turned a real 50 km/h limit into a bogus "31".
int parseMaxspeed(String? raw, int fallback) {
  if (raw == null || raw.isEmpty) return fallback;
  final t = raw.toLowerCase().trim();
  if (t == 'none' ||
      t == 'signals' ||
      t == 'variable' ||
      t == 'walk' ||
      t == 'urban' ||
      t == 'rural') {
    return fallback;
  }
  final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(t);
  if (m == null) return fallback;
  final v = double.parse(m.group(1)!);
  // OSM stores imperial units verbatim — convert to km/h (the chip is km/h).
  var kmh = t.contains('mph')
      ? v * 1.609344
      : t.contains('knot')
      ? v * 1.852
      : v;
  // A posted limit outside 5..200 km/h is data noise, not a real road.
  if (kmh < 5 || kmh > 200) return fallback;
  return kmh.round();
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
/// [vehicle] selects the statutory fallback (car/motorbike/truck); a positive
/// [override] (km/h) wins over both the tagged maxspeed and the fallback.
Future<RoadInfo?> fetchRoadInfo(
  LatLng pos, {
  String vehicle = 'car',
  int override = 0,
}) async {
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
  final (label, _) = classInfo(highway);
  final fallback = statutoryLimit(highway, vehicle: vehicle);
  final info = RoadInfo(
    name: (tags['name'] ?? '') as String,
    highway: highway,
    // Prefer the plain maxspeed, then the directional / conditional
    // variants. `maxspeed:forward` is usually a superset of `maxspeed` on
    // dual carriageways (both directions are posted separately), but the
    // plain tag is the more reliable base value, so it wins when present.
    maxspeed: _effectiveMaxspeed(tags),
    label: label,
    speedLimit: override > 0
        ? override
        : parseMaxspeed(_effectiveMaxspeed(tags), fallback),
  );
  _cache.last = info;
  _cache.at = pos;
  return info;
}

/// Best maxspeed tag on the way: `maxspeed` (base), falling back to
/// `maxspeed:forward` / `maxspeed:backward` / `maxspeed:conditional`.
/// OSM often only posts one of these on Vietnamese dual carriageways.
String? _effectiveMaxspeed(Map<String, dynamic> tags) {
  final plain = tags['maxspeed'];
  if (plain is String && plain.trim().isNotEmpty) return plain.trim();
  for (final k in [
    'maxspeed:forward',
    'maxspeed:backward',
    'maxspeed:conditional',
    'maxspeed:forward:conditional',
    'maxspeed:backward:conditional',
  ]) {
    final v = tags[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
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
