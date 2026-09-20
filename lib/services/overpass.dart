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
import 'dart:math' as math;

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

  /// OSM `oneway` tag: true = one-way, false = two-way, null = untagged.
  final bool? oneway;

  /// OSM `lanes` tag — lanes in THIS carriageway (null when untagged).
  final int? lanes;

  /// The car is on a "đường đôi" (divided road / có dải phân cách): either the
  /// way is `oneway=yes` with ≥2 motor lanes, or another way of the SAME street
  /// running the opposite way sits within ~35 m.
  ///
  /// VN mappers model a dải phân cách by drawing each direction as its own
  /// `oneway=yes` way — there is NO median tag in VN data (0 of 9,011 highway
  /// ways sampled in HCMC / Đà Nẵng carry `dual_carriageway`, `median`,
  /// `divider`, `central_median` or `separation`), so the pair structure is the
  /// only usable signal.
  final bool divided;

  RoadInfo({
    required this.name,
    required this.highway,
    this.maxspeed,
    required this.label,
    required this.speedLimit,
    this.oneway,
    this.lanes,
    this.divided = false,
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
///
/// Non-drivable classes (service, footway, pedestrian, cycleway) return an
/// EMPTY label — the app is a motor-vehicle nav, and "Đường nội bộ"/"Lối đi
/// bộ"/"Phố đi bộ" are not roads the driver is legitimately on, so showing
/// them as the road type was confusing (and the motorbike nav must not
/// claim to be driving down a sidewalk).
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
  'living_street' => ('', 20), // không phải đường cho xe cơ giới — bỏ nhãn
  'service' => ('', 30), // đường nội bộ — không phải đường chính, bỏ nhãn
  'pedestrian' => ('', 10), // phố đi bộ — không phải đường xe, bỏ nhãn
  'footway' => ('', 10), // lối đi bộ/vỉa hè — bỏ nhãn
  'cycleway' => ('', 20), // đường xe đạp — bỏ nhãn
  'path' => ('', 10),
  'track' => ('Đường đất', 30),
  _ => ('Đường', 50),
};

/// Vietnamese statutory default limit (km/h) per highway class per vehicle.
/// OSM rarely tags `maxspeed` in VN cities, so this fills the gap. The car
/// table mirrors [classInfo]; motorbike / truck are lower (motorbikes are
/// prohibited on motorways — capped rather than 0 so the chip never shows an
/// empty limit).
int statutoryLimit(
  String highway, {
  String vehicle = 'car',
  bool? oneway,
  int? lanes,
  bool divided = false,
}) {
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
    // Built-up two-way car limit is 50 (Thông tư 38/2024/TT-BGTVT); 40 is the
    // XE GẮN MÁY (moped) figure, not the car one, and it made city streets
    // read low. The "đường đôi / một chiều ≥2 làn" = 60 case is applied by
    // [urbanLimit] once oneway/lanes are known.
    'unclassified': 50,
    'residential': 50,
    'living_street': 20,
    'service': 30,
    'pedestrian': 10,
    'footway': 10,
    'cycleway': 20,
  };
  // Xe mô tô (2/3 bánh) — Thông tư 38/2024/TT-BGTVT (hiệu lực 01/01/2025):
  //   ngoài khu đông dân cư: 60 km/h (đường hai chiều không dải phân cách —
  //   điển hình QL1A) hoặc 70 (đường đôi / ≥2 làn); trong khu đông dân cư:
  //   50 (hai chiều) hoặc 60 (đường đôi). Default to the 2-way value; real
  //   posted signs (DATMAP/Waze/OSM) tighten it where present. (Xe gắn máy
  //   = 40 everywhere; mô tô bị cấm trên cao tốc — capped, not 0.)
  const motorbike = {
    'motorway': 80,
    'motorway_link': 60,
    'trunk': 60,
    'trunk_link': 50,
    'primary': 60,
    'primary_link': 50,
    'secondary': 60,
    'secondary_link': 50,
    'tertiary': 60,
    'tertiary_link': 50,
    'unclassified': 50,
    'residential': 50,
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
  final base = table[highway] ?? 50;
  // `residential` / `unclassified` are built-up street classes by definition,
  // so the "khu đông dân cư" rule applies whether or not a boundary sign was
  // crossed: đường đôi / một chiều ≥2 làn → 60, hai chiều → 50. Higher classes
  // keep the class default (their limit depends on urban/rural, which OSM
  // cannot tell us), and living_street / service keep their stricter value.
  if (highway == 'residential' || highway == 'unclassified') {
    return urbanLimit(
      vehicle: vehicle,
      oneway: oneway,
      lanes: lanes,
      divided: divided,
    );
  }
  return base;
}

/// Effective speed limit for [vehicle] on [highway], given an optional OSM
/// `maxspeed` tag ([taggedKmh], 0 = untagged / unusable).
///
/// OSM `maxspeed` is a CAR-oriented tag: for a car it IS the posted limit,
/// with the statutory class default as fallback. For motorbikes / trucks the
/// car limit only ever TIGHTENS the vehicle's statutory class default — it
/// never lifts it (a motorbike must not show 80 km/h just because the car
/// lane is posted 80), so non-car vehicles use the VN statutory per-class
/// table, capped by a lower posted sign.
int effectiveLimit(
  String highway, {
  required String vehicle,
  int taggedKmh = 0,
  bool? oneway,
  int? lanes,
  bool divided = false,
}) {
  final statutory = statutoryLimit(
    highway,
    vehicle: vehicle,
    oneway: oneway,
    lanes: lanes,
    divided: divided,
  );
  if (taggedKmh <= 0) return statutory;
  return vehicle == 'car' ? taggedKmh : math.min(statutory, taggedKmh);
}

/// Parse the OSM `oneway` tag → true (one-way) / false (two-way) / null
/// (untagged). `-1` and `reverse` are OSM's "one-way, against the way
/// direction" spellings — still one-way.
bool? parseOneway(String? raw) {
  if (raw == null) return null;
  switch (raw.trim().toLowerCase()) {
    case 'yes':
    case 'true':
    case '1':
    case '-1':
    case 'reverse':
      return true;
    case 'no':
    case 'false':
    case '0':
      return false;
  }
  return null; // "alternating", "reversible", … — no usable signal
}

/// Parse the OSM `lanes` tag → lanes in THIS carriageway (1..8), else null.
/// Multi/odd values ("2;3", "2.5", 0) are ignored rather than guessed.
int? parseLanes(Object? raw) {
  if (raw == null) return null;
  final m = RegExp(r'(\d+)').firstMatch(raw.toString());
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null || n < 1 || n > 8) return null;
  return n;
}

/// Posted limit INSIDE "khu đông dân cư" (built-up area) for [vehicle].
///
/// Thông tư 38/2024/TT-BGTVT (hiệu lực 01/01/2025) splits the built-up limit
/// by ROAD FORM, not by road class:
///   đường đôi / đường một chiều có từ hai làn xe cơ giới → 60 (ô tô, mô tô)
///   đường hai chiều / đường một chiều một làn             → 50 (ô tô, mô tô)
///   xe tải                                                → 50 / 40
///
/// "Đường đôi" = two carriageways split by a dải phân cách. OSM carries no
/// median tag in VN, so the two usable signals are [divided] (an opposite-way
/// carriageway of the same street sits alongside) and a one-way way that
/// itself carries ≥2 motor lanes ([oneway] + [lanes]).
int urbanLimit({
  required String vehicle,
  bool? oneway,
  int? lanes,
  bool divided = false,
}) {
  // `lanes` unknown defaults to 2: a street the mappers made one-way is a
  // through street (≥2 làn), while an explicit `lanes=1` is a genuine single
  // lane. This also keeps the answer stable on the many ways of the SAME
  // divided road that carry no `lanes` tag (5 of Lũy Bán Bích's 11 ways).
  final isDivided = divided || (oneway == true && (lanes ?? 2) >= 2);
  if (vehicle == 'truck') return isDivided ? 50 : 40;
  return isDivided ? 60 : 50;
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
/// [vehicle] selects the statutory fallback (car/motorbike/truck). OSM
/// `maxspeed` is a CAR-oriented tag: for a car it IS the posted limit; for
/// motorbikes / trucks it only tightens the vehicle's statutory class
/// default (it never lifts it).
Future<RoadInfo?> fetchRoadInfo(
  LatLng pos, {
  String vehicle = 'car',
  double? heading,
}) async {
  final cached = _cache.last;
  if (cached != null && _cache.at != null) {
    if (distanceMeters(pos, _cache.at!) < 25) return cached;
  }

  final query =
      '[out:json][timeout:10];'
      'way(around:30,${pos.latitude},${pos.longitude})[highway];'
      'out tags geom;';

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

  // Score each candidate: perpendicular distance to the way's REAL geometry +
  // a road-class penalty + heading agreement. The old nearest-centre pick let
  // a parallel service / residential frontage road beat the main road the car
  // is actually on (the "residential shown on a main road" bug).
  Map<String, dynamic>? best;
  var bestScore = double.infinity;
  for (final e in pool) {
    final tags = (e['tags'] as Map<String, dynamic>? ?? {});
    final hw = (tags['highway'] ?? '') as String;
    final geom = e['geometry'] as List? ?? const [];
    final (d, segBearing) = _nearestSegment(pos, geom);
    if (!d.isFinite) continue;
    final classPenalty = (_classPriority[hw] ?? 20) * 8.0;
    var headingPenalty = 0.0;
    if (heading != null) {
      headingPenalty = _angDiff(heading, segBearing) / 90.0 * 20.0;
    }
    final score = d + classPenalty + headingPenalty;
    if (score < bestScore) {
      bestScore = score;
      best = e;
    }
  }
  if (best == null) return cached;

  final tags = (best['tags'] as Map<String, dynamic>? ?? {});
  final highway = (tags['highway'] ?? '') as String;
  final (label, _) = classInfo(highway);
  final tagged = _effectiveMaxspeed(tags);
  final taggedKmh = tagged == null ? 0 : parseMaxspeed(tagged, 0);
  final oneway = parseOneway(tags['oneway'] as String?);
  final lanes = parseLanes(tags['lanes']);
  // "Đường đôi" detection: another way of the SAME street running roughly the
  // opposite way, close enough to be the other carriageway of a dải phân cách.
  final divided = _hasOppositeCarriageway(pos, best, pool);
  final info = RoadInfo(
    name: (tags['name'] ?? '') as String,
    highway: highway,
    // Prefer the plain maxspeed, then the directional / conditional
    // variants. `maxspeed:forward` is usually a superset of `maxspeed` on
    // dual carriageways (both directions are posted separately), but the
    // plain tag is the more reliable base value, so it wins when present.
    maxspeed: tagged,
    label: label,
    speedLimit: effectiveLimit(
      highway,
      vehicle: vehicle,
      taggedKmh: taggedKmh,
      oneway: oneway,
      lanes: lanes,
      divided: divided,
    ),
    oneway: oneway,
    lanes: lanes,
    divided: divided,
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

/// Road-class priority for candidate scoring (0 = highest). Lower is better;
/// each step is ~8 m of "distance" so a parallel service road loses to a main
/// road unless it is genuinely much closer.
const Map<String, int> _classPriority = {
  'motorway': 0,
  'motorway_link': 1,
  'trunk': 2,
  'trunk_link': 3,
  'primary': 4,
  'primary_link': 5,
  'secondary': 6,
  'secondary_link': 7,
  'tertiary': 8,
  'tertiary_link': 9,
  'unclassified': 10,
  'residential': 11,
  'living_street': 12,
  'service': 13,
  'track': 14,
  'path': 15,
  'pedestrian': 16,
  'footway': 17,
  'cycleway': 18,
  'steps': 19,
};

/// Perpendicular distance from [p] to the way's node polyline, plus the
/// bearing (deg, 0=N) of the nearest segment. Returns (∞, 0) when the way has
/// no usable geometry.
(double, double) _nearestSegment(LatLng p, List<dynamic> geom) {
  final pts = <LatLng>[
    for (final g in geom)
      if (g is Map && g['lat'] != null && g['lon'] != null)
        LatLng((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
  ];
  if (pts.length < 2) {
    if (pts.isEmpty) return (double.infinity, 0);
    return (distanceMeters(p, pts.first), 0);
  }
  final mPerDegLat = 111320.0;
  final mPerDegLng = mPerDegLat * math.cos(p.latitude * math.pi / 180);
  var bestD = double.infinity;
  var bestBearing = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final ax = (a.longitude - p.longitude) * mPerDegLng;
    final ay = (a.latitude - p.latitude) * mPerDegLat;
    final bx = (b.longitude - p.longitude) * mPerDegLng;
    final by = (b.latitude - p.latitude) * mPerDegLat;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 < 1e-12 ? 0.0 : ((0 - ax) * dx + (0 - ay) * dy) / len2;
    final tt = t.clamp(0.0, 1.0).toDouble();
    final px = ax + tt * dx, py = ay + tt * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < bestD) {
      bestD = d;
      bestBearing = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
    }
  }
  return (bestD, bestBearing);
}

/// Smallest angle between two bearings in [0, 90] — roads are bidirectional,
/// so a 180° difference is the SAME road (0°).
double _angDiff(double a, double b) {
  var d = ((a - b) % 360).abs();
  if (d > 180) d = 360 - d;
  if (d > 90) d = 180 - d;
  return d;
}

/// Raw difference between two bearings in [0, 180] — the folded [_angDiff]
/// cannot tell "same direction" from "opposite direction" (both give 0°),
/// which is exactly the distinction a dual carriageway needs.
double _bearingDelta(double a, double b) {
  var d = ((a - b) % 360).abs();
  if (d > 180) d = 360 - d;
  return d;
}

/// Whether [best] is one carriageway of a divided road (đường đôi): some OTHER
/// [pool] way with the same street name/ref sits within ~35 m of [pos] and runs
/// roughly the opposite way (>120° apart, or the reverse bearing). Only the
/// other carriageway of a dải phân cách is that close AND that anti-parallel.
bool _hasOppositeCarriageway(
  LatLng pos,
  Map<String, dynamic> best,
  List<Map<String, dynamic>> pool,
) {
  final bt = (best['tags'] as Map<String, dynamic>? ?? {});
  final name = (bt['name'] ?? '') as String;
  final ref = (bt['ref'] ?? '') as String;
  if (name.isEmpty && ref.isEmpty) return false;
  final (_, bestBearing) = _nearestSegment(
    pos,
    best['geometry'] as List? ?? const [],
  );
  for (final e in pool) {
    if (identical(e, best)) continue;
    final t = (e['tags'] as Map<String, dynamic>? ?? {});
    if (t['highway'] is! String) continue;
    final en = (t['name'] ?? '') as String;
    final er = (t['ref'] ?? '') as String;
    final sameStreet =
        (name.isNotEmpty && en == name) || (ref.isNotEmpty && er == ref);
    if (!sameStreet) continue;
    final (d, b) = _nearestSegment(pos, e['geometry'] as List? ?? const []);
    if (!d.isFinite || d > 35) continue;
    // Only the ANTI-parallel case counts (>120° apart). A same-direction
    // duplicate way (<20°) is not a divided road, and an ordinary parallel
    // street fails the same-street test above.
    if (_bearingDelta(bestBearing, b) > 120) return true;
  }
  return false;
}
