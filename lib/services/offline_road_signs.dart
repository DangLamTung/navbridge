/// Offline road-sign index for Việt Nam — bundled as a compact JSON
/// (`assets/offline_map/vietnam_signs.json`) generated from OSM Overpass
/// (`tools/signs/build_signs.py`).
///
/// Works with NO network (like `offline_cameras.dart`). Covers the sign kinds
/// drivers actually need to be warned about: STOP signs, give-way (nhường
/// đường) signs, and traffic lights. During navigation the app finds the
/// next sign AHEAD on the route and warns the driver when close.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'offline_scan.dart';

/// The kind of road sign — drives the map icon and the spoken warning.
/// Uses Việt Nam standard signage (QCVN 41:2019/BGTVT) codes where relevant
/// (P.123 cấm rẽ trái, P.124 cấm rẽ phải, P.125 cấm quay đầu, P.127 cấm vượt,
/// P.133 hết mọi lệnh cấm, R.41x hướng phải đi, khu đông dân cư…).
enum RoadSignKind {
  stop('stop', 'Biển STOP'),
  giveWay('giveWay', 'Biển nhường đường'),
  speed('speed', 'Hạn chế tốc độ'),
  populated('populated', 'Bắt đầu khu đông dân cư'),
  signal('signal', 'Đèn giao thông'),
  populatedEnd('populated_end', 'Hết khu đông dân cư'),
  noPassing('no_passing', 'P.127 Cấm vượt'),
  noPassingEnd('no_passing_end', 'Hết cấm vượt'),
  noLeftTurn('no_left_turn', 'P.123 Cấm rẽ trái'),
  noRightTurn('no_right_turn', 'P.124 Cấm rẽ phải'),
  noUTurn('no_u_turn', 'P.125 Cấm quay đầu'),
  noLeftUTurn('no_left_uturn', 'P.123a Cấm rẽ trái và quay đầu'),
  noRightUTurn('no_right_uturn', 'P.124a Cấm rẽ phải và quay đầu'),
  onlyStraight('only_straight', 'R.411 Hướng phải đi thẳng'),
  onlyLeft('only_left', 'R.412a Hướng phải rẽ trái'),
  onlyRight('only_right', 'R.412 Hướng phải rẽ phải'),
  endProhibitions('end_prohibitions', 'P.133 Hết mọi lệnh cấm');

  const RoadSignKind(this.key, this.label);

  /// JSON key (matches the generator output).
  final String key;

  /// Vietnamese label.
  final String label;

  static RoadSignKind fromKey(String k) => switch (k) {
    'stop' => stop,
    'giveWay' => giveWay,
    'speed' => speed,
    'populated' => populated,
    'populated_end' => populatedEnd,
    'no_passing' => noPassing,
    'no_passing_end' => noPassingEnd,
    'no_left_turn' => noLeftTurn,
    'no_right_turn' => noRightTurn,
    'no_u_turn' => noUTurn,
    'no_left_uturn' => noLeftUTurn,
    'no_right_uturn' => noRightUTurn,
    'only_straight' => onlyStraight,
    'only_left' => onlyLeft,
    'only_right' => onlyRight,
    'end_prohibitions' => endProhibitions,
    _ => signal,
  };
}

/// One road-sign point.
class RoadSign implements OfflinePoint {
  final String name;
  final double lat;
  final double lng;
  final RoadSignKind kind;

  /// Speed limit (km/h) for [RoadSignKind.speed] signs (null otherwise).
  final int? value;

  const RoadSign({
    required this.name,
    required this.lat,
    required this.lng,
    required this.kind,
    this.value,
  });

  @override
  LatLng get pos => LatLng(lat, lng);

  /// Straight-line distance (m) from [p].
  double distanceM(LatLng p) => const Distance().as(LengthUnit.Meter, p, pos);

  factory RoadSign.fromJson(Map<String, dynamic> j) => RoadSign(
    name: (j['name'] ?? '') as String,
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
    kind: RoadSignKind.fromKey((j['kind'] ?? 'signal') as String),
    value: (j['value'] as num?)?.toInt(),
  );
}

/// A sign that is AHEAD of the driver on the route.
class SignAhead {
  final RoadSign sign;

  /// Distance along the route (not straight-line) from the car, metres.
  final double routeMeters;

  const SignAhead({required this.sign, required this.routeMeters});
}

List<RoadSign>? _signs;
bool _loaded = false;
Future<List<RoadSign>>? _loading;

/// Load the bundled sign index once (idempotent, cached).
Future<List<RoadSign>> loadOfflineRoadSigns() {
  if (_signs != null) return Future.value(_signs!);
  if (_loading != null) return _loading!;
  final fut = _doLoad();
  _loading = fut;
  return fut;
}

Future<List<RoadSign>> _doLoad() async {
  if (_loaded && _signs != null) return _signs!;
  _loaded = true;
  try {
    final raw = await rootBundle.loadString(
      'assets/offline_map/vietnam_signs.json',
    );
    final data = jsonDecode(raw) as Map<String, dynamic>;
    _signs = [
      for (final it
          in (data['signs'] as List? ?? const []).cast<Map<String, dynamic>>())
        RoadSign.fromJson(it),
    ];
  } catch (_) {
    _signs = const [];
  }
  return _signs!;
}

/// Find the first sign AHEAD of [current] along [geometry], ordered by
/// distance along the route, limited to [maxAheadMeters] ahead.
///
/// Runs in a BACKGROUND ISOLATE so the per-second nav check never blocks the
/// UI thread on a long route (same approach as [camerasAheadOnRoute]).
Future<List<SignAhead>> signsAheadOnRoute(
  LatLng current,
  List<LatLng> geometry, {
  double maxAheadMeters = 1500,
}) async {
  final signs = await loadOfflineRoadSigns();
  if (signs.isEmpty || geometry.length < 2) return const [];
  final res = await compute(pointsAheadOnRoute<RoadSign>, (
    current,
    geometry,
    signs,
    maxAheadMeters,
  ));
  return [for (final (i, m) in res) SignAhead(sign: signs[i], routeMeters: m)];
}

// The isolate workers (`pointsAheadOnRoute` / `pointsNearRoute`) live in
// `offline_scan.dart`; see [signsAheadOnRoute] / [signsNearRoute].

/// Signs within ~[corridorMeters] of the route polyline — the nav-map layer
/// shows ONLY these (not all ~11k nationwide), so the driver sees the signs
/// that are actually on/near the road they're taking.
Future<List<RoadSign>> signsNearRoute(
  List<LatLng> geometry, {
  double corridorMeters = 200,
}) async {
  final signs = await loadOfflineRoadSigns();
  if (signs.isEmpty || geometry.length < 2) return const [];
  final idxs = await compute(pointsNearRoute<RoadSign>, (
    geometry,
    signs,
    corridorMeters,
  ));
  return [for (final i in idxs) signs[i]];
}

// Route scanning (`pointsAheadOnRoute` / `pointsNearRoute`) lives in
// `offline_scan.dart`; polyline helpers live in `offline_geo.dart`.
