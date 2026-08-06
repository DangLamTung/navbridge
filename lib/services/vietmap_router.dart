/// Vietmap route v4 — fast Vietnam routing with real-time congestion.
///
/// Supports `car` and `motorcycle` (bicycle/foot aren't offered → those fall
/// back to OSRM). The response is GraphHopper-shaped; each step carries the
/// live congestion level so the route line can be colored like Google Maps.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/vietmap_config.dart';

const _ua = 'navbridge/1.0 (Vietmap route)';

/// Route [points] via Vietmap route v4.
/// [vehicle]: 'car' | 'motorcycle'.
Future<OsrmRoute> fetchVietmapRoute(
  List<LatLng> points, {
  String vehicle = 'car',
}) async {
  final routes = await fetchVietmapRoutes(points, vehicle: vehicle);
  if (routes.isEmpty) throw Exception('Không tìm thấy tuyến đường');
  return routes.first;
}

/// Fetch up to [maxAlternatives] route options (Vietmap `alternative=true`).
/// The best route is first; the rest are alternatives for the preview UI.
/// Each route carries its own toll data (`annotations=congestion,toll`).
Future<List<OsrmRoute>> fetchVietmapRoutes(
  List<LatLng> points, {
  String vehicle = 'car',
  int maxAlternatives = 3,
}) async {
  if (points.length < 2) throw Exception('Cần ít nhất 2 điểm để định tuyến');
  final pts = points.map((p) => 'point=${p.latitude},${p.longitude}').join('&');
  final url = '${VietmapConfig.route}?apikey=${VietmapConfig.apiKey}'
      '&$pts&vehicle=$vehicle&points_encoded=false'
      '&annotations=congestion,toll&alternative=true';
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': _ua})
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) throw Exception('Vietmap HTTP ${res.statusCode}');
  final data = jsonDecode(utf8.decode(res.bodyBytes));
  final paths =
      (data is Map && data['code'] == 'OK') ? data['paths'] as List? : null;
  if (paths == null || paths.isEmpty) {
    throw Exception('Không tìm thấy tuyến đường');
  }
  return [
    for (final p in paths)
      if (p is Map) _parsePath(Map<String, dynamic>.from(p))
  ].take(maxAlternatives).toList();
}

/// Parse one Vietmap `paths[]` entry into an [OsrmRoute] (geometry, steps,
/// congestion, tolls).
OsrmRoute _parsePath(Map<String, dynamic> r) {
  // Geometry: GeoJSON LineString → [[lon, lat], ...].
  final coords = (((r['points'] as Map?)?['coordinates'] as List?) ?? const [])
      .cast<dynamic>()
      .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
      .toList();

  final congestion = _parseCongestion(r['annotations']);
  final rawSteps = (r['instructions'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final steps = <OsrmStep>[];
  final stopCum = <double>[];
  var cum = 0.0;
  for (final s in rawSteps) {
    final sign = ((s['sign'] ?? 0) as num).toInt();
    final (type, modifier) = _maneuverForSign(sign);
    final dist = ((s['distance'] ?? 0) as num).toDouble();
    cum += dist;
    final iv = (s['interval'] as List?)?.cast<num>() ?? const [];
    final mi = iv.length > 1 ? iv[1].toInt() : 0;
    final maneuver = mi < coords.length
        ? coords[mi]
        : (coords.isEmpty ? const LatLng(0, 0) : coords.last);
    steps.add(OsrmStep(
      name: '${s['street_name'] ?? ''}',
      distance: dist,
      duration: ((s['time'] ?? 0) as num).toDouble() / 1000.0,
      type: type,
      modifier: modifier,
      maneuver: maneuver,
      congestion: _congestionFor(interval: iv, segments: congestion),
    ));
    if (sign == 5 || sign == 4) stopCum.add(cum);
  }
  if (stopCum.isEmpty && cum > 0) stopCum.add(cum);

  // Toll data (Vietmap `annotations=congestion,toll`).
  final tollCost = (r['toll_cost'] as num?)?.toInt();
  final tolls = <TollInfo>[];
  final rawTolls = r['tolls'];
  if (rawTolls is List) {
    for (final t in rawTolls) {
      if (t is! Map) continue;
      final name = '${t['name'] ?? ''}'.trim();
      final addr = '${t['address'] ?? ''}'.trim();
      if (name.isEmpty && addr.isEmpty) continue;
      tolls.add(TollInfo(
        name: name,
        address: addr,
        type: '${t['type'] ?? ''}',
        price: ((t['price'] ?? 0) as num).toInt(),
      ));
    }
  }

  return OsrmRoute(
    distance: ((r['distance'] ?? 0) as num).toDouble(),
    duration: ((r['time'] ?? 0) as num).toDouble() / 1000.0,
    geometry: coords,
    steps: steps,
    stopCumulative: stopCum,
    tollCost: tollCost,
    tolls: tolls,
  );
}

typedef _CongSeg = ({String value, int first, int last});

/// annotations.congestion → [{value, first, last}] segments (point indices).
List<_CongSeg> _parseCongestion(dynamic annotations) {
  if (annotations is! Map) return const [];
  final list = annotations['congestion'];
  if (list is! List) return const [];
  return [
    for (final e in list)
      if (e is Map)
        (
          value: '${e['value'] ?? 'unknown'}',
          first: ((e['first'] ?? 0) as num).toInt(),
          last: ((e['last'] ?? 0) as num).toInt(),
        )
  ];
}

/// Worst congestion level overlapping an instruction's [startIdx, endIdx].
/// Returns 0 low · 1 moderate · 2 heavy/severe · null unknown.
int? _congestionFor({
  required List<num> interval,
  required List<_CongSeg> segments,
}) {
  if (interval.length < 2 || segments.isEmpty) return null;
  final s = interval[0].toInt();
  final e = interval[1].toInt();
  var worst = -1;
  for (final seg in segments) {
    if (seg.last < s || seg.first > e) continue;
    final lvl = switch (seg.value) {
      'low' => 0,
      'moderate' => 1,
      'heavy' || 'severe' => 2,
      _ => -1,
    };
    if (lvl > worst) worst = lvl;
  }
  return worst < 0 ? null : worst;
}

/// Vietmap/GraphHopper instruction sign → OSRM-style maneuver.
(String, String?) _maneuverForSign(int sign) => switch (sign) {
      -3 => ('turn', 'sharp left'),
      -2 => ('turn', 'left'),
      -1 => ('turn', 'slight left'),
      0 => ('continue', 'straight'),
      1 => ('turn', 'slight right'),
      2 => ('turn', 'right'),
      3 => ('turn', 'sharp right'),
      6 => ('roundabout', 'left'),
      4 || 5 => ('arrive', null),
      _ => ('continue', 'straight'),
    };
