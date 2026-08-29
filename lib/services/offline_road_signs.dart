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

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'offline_loader.dart';
import 'offline_scan.dart';
import 'offline_scan_isolate.dart';

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

final OfflineListLoader<RoadSign> _signs = OfflineListLoader<RoadSign>(
  _fetchSigns,
);

/// Load the bundled sign index once (idempotent, cached).
Future<List<RoadSign>> loadOfflineRoadSigns() => _signs.load();

Future<List<RoadSign>> _fetchSigns() async {
  final raw = await rootBundle.loadString(
    'assets/offline_map/vietnam_signs.json',
  );
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final it
        in (data['signs'] as List? ?? const []).cast<Map<String, dynamic>>())
      RoadSign.fromJson(it),
  ];
}

/// Find the first sign AHEAD of [current] along [geometry], ordered by
/// distance along the route, limited to [maxAheadMeters] ahead.
///
/// Runs in the PERSISTENT BACKGROUND ISOLATE ([OfflineScanIsolate]) that
/// keeps the sign DB resident — a fresh `compute()` per call would deep-copy
/// the whole ~11k-sign list onto the main thread EVERY second (same freeze
/// mechanism as the cameras on long routes).
Future<List<SignAhead>> signsAheadOnRoute(
  LatLng current,
  List<LatLng> geometry, {
  double maxAheadMeters = 1500,
}) async {
  return OfflineScanIsolate.instance.signsAhead(
    current,
    geometry,
    maxAheadMeters: maxAheadMeters,
  );
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
  return OfflineScanIsolate.instance.signsNear(
    geometry,
    corridorMeters: corridorMeters,
  );
}

/// Signs within [maxDistM] of a POINT — the nav-map layer WHILE DRIVING only
/// needs the handful near the car. A whole long route can hold 2,000+ signs
/// as native icon overlays (crushing the low-end phone at large zoom), so the
/// driving layer is bounded to near-car signs, refreshed every few seconds.
/// Cheap bbox pre-filter over the ~11k DB (not a route-wide isolate scan).
/// Most important signs first (cấm rẽ / quay đầu / vượt / khu dân cư → STOP /
/// nhường đường → traffic lights), then distance; deduped + capped at [max].
Future<List<RoadSign>> signsNearPoint(
  LatLng pos, {
  double maxDistM = 4000,
  int max = 40,
}) async {
  final signs = await loadOfflineRoadSigns();
  if (signs.isEmpty) return const [];
  const Distance d = Distance();
  final span = maxDistM / 111320.0;
  final out = <(RoadSign, double)>[];
  for (final s in signs) {
    if (s.lat < pos.latitude - span ||
        s.lat > pos.latitude + span ||
        s.lng < pos.longitude - span ||
        s.lng > pos.longitude + span) {
      continue;
    }
    final m = d.as(LengthUnit.Meter, pos, s.pos);
    if (m <= maxDistM) out.add((s, m));
  }
  out.sort((a, b) {
    final pa = _signPriority(a.$1.kind);
    final pb = _signPriority(b.$1.kind);
    return pa != pb ? pa.compareTo(pb) : a.$2.compareTo(b.$2);
  });
  final speedBuckets = <String>{};
  final signalBuckets = <String>{};
  final kept = <RoadSign>[];
  for (final (s, _) in out) {
    if (kept.length >= max) break;
    if (s.kind == RoadSignKind.speed) {
      final bucket =
          '${s.value}/${(s.lat / 0.003).round()},${(s.lng / 0.003).round()}';
      if (!speedBuckets.add(bucket)) continue;
    } else if (s.kind == RoadSignKind.signal) {
      final bucket = '${(s.lat / 0.0012).round()},${(s.lng / 0.0012).round()}';
      if (!signalBuckets.add(bucket)) continue;
    }
    kept.add(s);
  }
  return kept;
}

/// Driving-importance rank for the sign chips / map layer: cấm rẽ / quay đầu /
/// cấm vượt AND khu dân cư boundaries FIRST (the driver must see them), then
/// STOP / nhường đường, then the rest. Two signs at the same rank sort by
/// distance.
int _signPriority(RoadSignKind k) => switch (k) {
  RoadSignKind.noLeftTurn ||
  RoadSignKind.noRightTurn ||
  RoadSignKind.noUTurn ||
  RoadSignKind.noLeftUTurn ||
  RoadSignKind.noRightUTurn ||
  RoadSignKind.noPassing ||
  RoadSignKind.noPassingEnd ||
  RoadSignKind.populated ||
  RoadSignKind.populatedEnd => 0, // cấm rẽ / quay đầu / vượt + khu dân cư
  RoadSignKind.stop || RoadSignKind.giveWay => 1,
  _ => 2,
};

/// Pick the SINGLE most important sign from route-ahead signs (cấm rẽ / quay
/// đầu / vượt / khu dân cư first, then STOP / nhường đường) — the widget shows
/// only this one nearest-on-route sign. Speed signs (already on the R.301
/// badge) and traffic lights (map-only) are skipped.
SignAhead? bestSignAhead(List<SignAhead> ahead) {
  if (ahead.isEmpty) return null;
  SignAhead? best;
  var bestP = 99;
  for (final a in ahead) {
    if (a.sign.kind == RoadSignKind.speed ||
        a.sign.kind == RoadSignKind.signal) {
      continue;
    }
    final p = _signPriority(a.sign.kind);
    if (p < bestP) {
      bestP = p;
      best = a;
    }
  }
  return best;
}

/// Ordered list of road-sign chips for the floating widget (sign + metres):
/// every non-speed / non-signal sign within [maxDistM] (800 m), sorted by
/// DRIVING IMPORTANCE first (cấm rẽ / quay đầu / cấm vượt / khu dân cư → STOP
/// / nhường đường → rest), then distance — so cấm rẽ trái/phải, cấm quay đầu
/// and khu dân cư always appear ahead of a nearer but less critical sign.
/// Speed signs are already shown by the R.301 badge and traffic lights are
/// map-only, so both are excluded. Capped at [max] chips.
Future<List<(RoadSign, int)>> signsForWidgetChips(
  LatLng pos, {
  double maxDistM = 800,
  int max = 6,
}) async {
  final near = await signsNearPoint(pos, maxDistM: maxDistM);
  if (near.isEmpty) return const [];
  const Distance d = Distance();
  final all = <(RoadSign, int)>[];
  for (final s in near) {
    if (s.kind == RoadSignKind.speed || s.kind == RoadSignKind.signal) {
      continue;
    }
    final m = d.as(LengthUnit.Meter, pos, s.pos).round();
    all.add((s, m));
  }
  all.sort((a, b) {
    final pa = _signPriority(a.$1.kind);
    final pb = _signPriority(b.$1.kind);
    return pa != pb ? pa.compareTo(pb) : a.$2.compareTo(b.$2);
  });
  return all.length > max ? all.sublist(0, max) : all;
}

// Route scanning (`pointsAheadOnRoute` / `pointsNearRoute`) lives in
// `offline_scan.dart`; polyline helpers live in `offline_geo.dart`.
