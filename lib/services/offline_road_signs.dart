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
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'offline_loader.dart';
import 'offline_scan.dart';
import 'offline_scan_isolate.dart';

/// The kind of road sign — drives the map icon and the spoken warning.
/// Uses Việt Nam standard signage (QCVN 41:2019/BGTVT) codes where relevant
/// (P.123 cấm rẽ trái, P.124 cấm rẽ phải, P.125 cấm quay đầu, P.127 cấm vượt,
/// P.133 hết mọi lệnh cấm, R.41x hướng phải đi…).
///
/// The built-up boundary ("bắt đầu / hết khu đông dân cư") is deliberately NOT
/// here — see [droppedSignKinds]; its data was wrong often enough to write a
/// wrong speed limit, so the whole layer is gone.
enum RoadSignKind {
  stop('stop', 'Biển STOP'),
  giveWay('giveWay', 'Biển nhường đường'),
  speed('speed', 'Hạn chế tốc độ'),
  signal('signal', 'Đèn giao thông'),
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
  endProhibitions('end_prohibitions', 'P.133 Hết mọi lệnh cấm'),
  slowDown('slow_down', 'Giảm tốc độ'),
  noAuto('no_auto', 'P.124a Cấm ô tô'),
  noMoto('no_moto', 'P.114 Cấm xe máy'),
  oneWay('one_way', 'Đường một chiều'),
  noStraight('no_straight', 'P.112 Cấm đi thẳng'),
  noTurnBoth('no_turn_both', 'Cấm rẽ trái và rẽ phải'),
  reservedLane('reserved_lane', 'Làn dành riêng'),
  noParking('no_parking', 'P.131a Cấm đỗ xe'),
  tollBooth('toll_booth', 'Trạm thu phí'),
  railwayCrossing('railway_crossing', 'Đường ngang giao với đường sắt'),
  tunnel('tunnel', 'Hầm đường bộ');

  const RoadSignKind(this.key, this.label);

  /// JSON key (matches the generator output).
  final String key;

  /// Vietnamese label.
  final String label;

  static RoadSignKind fromKey(String k) => switch (k) {
    'stop' => stop,
    'giveWay' => giveWay,
    'speed' => speed,
    // 'populated' / 'populated_end' (khu đông dân cư boundaries) are dropped
    // before this is reached — see [droppedSignKinds].
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
    'slow_down' => slowDown,
    'toll_booth' => tollBooth,
    'railway_crossing' => railwayCrossing,
    'tunnel' => tunnel,
    'no_auto' => noAuto,
    'no_moto' => noMoto,
    'one_way' => oneWay,
    'no_straight' => noStraight,
    'no_turn_both' => noTurnBoth,
    'reserved_lane' => reservedLane,
    'no_parking' => noParking,
    _ => signal,
  };

  /// Whether this sign is a major regulatory or safety notice (speed limit,
  /// no passing, stop, give way, toll booth, railway, tunnel) that should be
  /// visible on overview/zoomed-out maps. Minor local maneuvers (turn
  /// prohibitions, parking bans, traffic lights, one-way alleys) are suppressed
  /// when zoomed out to keep the map readable.
  bool get isImportant => switch (this) {
    speed ||
    noPassing ||
    noPassingEnd ||
    stop ||
    giveWay ||
    tollBooth ||
    railwayCrossing ||
    tunnel ||
    endProhibitions ||
    slowDown => true,
    _ => false,
  };
}

/// JSON `kind` values that are DROPPED at load time.
///
/// "bắt đầu / hết khu đông dân cư" boundaries arrive from VietMap E-DOG
/// (TYPE 9/10) and OSM — 9,211 points, 20.4% of the whole sign DB. They are
/// dropped for what they COST, not because the data is provably wrong
/// (measured by `tool/why_drop_kdc.py`):
///  * a third limit source (a built-up cap) that cannot be validated from a
///    recording — on 38 recorded drives NOT ONE boundary point came within
///    200 m of the track, so the cap never fired and never got checked;
///  * where one does sit on a Waze/WME segment (11% of them) that segment posts
///    more than the cap 39% of the time, so when it fires it overrides a posted
///    value instead of filling a gap;
///  * 9,211 rows of a 45,197-row DB are scanned every second by the sign
///    isolate for that.
///
/// Filtered HERE (not in the asset) so an already-downloaded
/// `vietnam_signs.json` from an older build stays usable.
const Set<String> droppedSignKinds = {'populated', 'populated_end'};

/// One road-sign point.
class RoadSign implements OfflinePoint {
  final String name;
  final double lat;
  final double lng;
  final RoadSignKind kind;

  /// Speed limit (km/h) for [RoadSignKind.speed] signs (null otherwise).
  final int? value;

  /// Data source that produced this point: `vietmap` | `osm` | `waze`.
  final String source;

  /// Major regulatory or safety sign eligible for overview / zoomed-out views.
  bool get isImportant => kind.isImportant;

  const RoadSign({
    required this.name,
    required this.lat,
    required this.lng,
    required this.kind,
    this.value,
    this.source = 'osm',
  });

  @override
  LatLng get pos => LatLng(lat, lng);

  /// Straight-line distance (m) from [p].
  double distanceM(LatLng p) => const Distance().as(LengthUnit.Meter, p, pos);

  factory RoadSign.fromJson(Map<String, dynamic> j) {
    final name = (j['name'] ?? '') as String;
    final source =
        (j['source'] as String?) ??
        (name.startsWith('Sign:') || j['kind'] == 'signal' ? 'osm' : 'vietmap');
    return RoadSign(
      name: name,
      lat: ((j['lat'] ?? 0) as num).toDouble(),
      lng: ((j['lng'] ?? 0) as num).toDouble(),
      kind: RoadSignKind.fromKey((j['kind'] ?? 'signal') as String),
      value: (j['value'] as num?)?.toInt(),
      source: source,
    );
  }
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

/// Drop the cached sign list so it re-reads from disk on next load — called
/// after an auto-update replaces the downloaded `vietnam_signs.json`.
void reloadOfflineRoadSigns() => _signs.reload();

Future<List<RoadSign>> _fetchSigns() async {
  // Prefers an auto-updated copy over the bundled asset — see readOfflineText.
  final raw = await readOfflineText('vietnam_signs.json');
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final it
        in (data['signs'] as List? ?? const []).cast<Map<String, dynamic>>())
      if (!droppedSignKinds.contains(it['kind'])) RoadSign.fromJson(it),
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
/// Most important signs first (cấm vượt / cấm rẽ / quay đầu → STOP /
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
  // Longitudes shrink with cos(lat); without this the bbox prunes signs that
  // are within range but due east/west (up to ~7% loss for Việt Nam).
  final lngSpan = span / math.cos(pos.latitude * math.pi / 180.0);
  final out = <(RoadSign, double)>[];
  for (final s in signs) {
    if (s.lat < pos.latitude - span ||
        s.lat > pos.latitude + span ||
        s.lng < pos.longitude - lngSpan ||
        s.lng > pos.longitude + lngSpan) {
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
  // Collapse the SAME physical sign recorded at a few-metre offset (Waze /
  // VietMap / DATMAP overlap) so a single posted limit never shows as a stack
  // of icons. Same KIND within ~100 m collapse (per user: "open to 100m, same
  // kind is ok too") — the driver wants ONE icon per sign post, even if two
  // sources recorded different values there. A STOP + speed limit at one post
  // are different kinds (both kept). The data is already deduped at the
  // source, so this is a display-time net. Check neighbouring grid cells so a
  // sign straddling a cell boundary still merges with its neighbour.
  const cell = 0.001; // ~111 m latitude
  final keptCells = <String, List<(RoadSign, double)>>{};
  final kept = <RoadSign>[];
  for (final (s, m) in out) {
    if (kept.length >= max) break;
    final gx = (s.lat / cell).floor();
    final gy = (s.lng / cell).floor();
    var dup = false;
    for (var dx = -1; dx <= 1 && !dup; dx++) {
      for (var dy = -1; dy <= 1 && !dup; dy++) {
        final cl = keptCells['${gx + dx},${gy + dy}'];
        if (cl == null) continue;
        for (final (i, _) in cl) {
          if (i.kind == s.kind && _approxM(i.lat, i.lng, s.lat, s.lng) < 100) {
            dup = true;
            break;
          }
        }
      }
    }
    if (dup) continue;
    (keptCells['$gx,$gy'] ??= <(RoadSign, double)>[]).add((s, m));
    kept.add(s);
  }
  return kept;
}

/// Approximate metres between two lat/lng (equirectangular, fine at ≤ a few
/// hundred metres — this only guards a ~100 m near-dup radius).
double _approxM(double la1, double lo1, double la2, double lo2) {
  const mPerDegLat = 111320.0;
  final lat = (la1 - la2) * mPerDegLat;
  final lng = (lo1 - lo2) * mPerDegLat * 0.95; // cos(VN lat ~18°)
  return math.sqrt(lat * lat + lng * lng);
}

/// Collapse REPEATED speed-limit signs that carry the SAME km/h within
/// [runMeters] of the previous kept one.
///
/// A limit posted every few hundred metres along a street is ONE piece of
/// information, not N icons — the driver asked for exactly that: "on 1 street,
/// u only need to show speed sign 1 time … instead add more sign is better".
/// Only `speed` signs collapse (a STOP every 500 m is still a real STOP), a
/// DIFFERENT value is a genuine change and is always kept, and the same value
/// reappearing after a long gap (new street / re-signed stretch) is kept too.
/// Input order is preserved, and every non-speed sign passes through untouched,
/// so the freed marker budget goes to the other kinds.
List<RoadSign> collapseRepeatedSpeedSigns(
  List<RoadSign> signs, {
  double runMeters = 2000,
}) {
  final out = <RoadSign>[];
  RoadSign? lastSpeed;
  for (final s in signs) {
    if (s.kind != RoadSignKind.speed || s.value == null) {
      out.add(s);
      continue;
    }
    final last = lastSpeed;
    if (last != null &&
        last.value == s.value &&
        _approxM(last.lat, last.lng, s.lat, s.lng) <= runMeters) {
      continue; // same limit still posted along this stretch
    }
    lastSpeed = s;
    out.add(s);
  }
  return out;
}

/// Keep ONLY the nearest speed sign of [signs] (ordered nearest-first within
/// the priority tier) — i.e. the limit that applies where the car is.
///
/// For the BROWSE (area) map only. The point layers post a speed sign every few
/// hundred metres, so a 6 km view held 384 of them; because speed ranks tier 0
/// they took the whole marker cap and the map showed NOTHING but speed signs
/// (user: "still too many speed sign … instead add more sign is better"). The
/// route/nav map keeps the per-stretch collapse instead, where the corridor is
/// narrow enough for the icons to be meaningful.
List<RoadSign> keepNearestSpeedSign(List<RoadSign> signs) {
  final out = <RoadSign>[];
  var kept = false;
  for (final s in signs) {
    if (s.kind != RoadSignKind.speed) {
      out.add(s);
      continue;
    }
    if (kept) continue;
    kept = true;
    out.add(s);
  }
  return out;
}

/// Driving-importance rank for the sign chips / map layer:
/// Tier 0: speed limit and cấm vượt (crucial for map & driving)
/// Tier 1: STOP, give way, toll, railway, tunnel, end prohibitions
/// Tier 2: turn prohibitions and directional rules
/// Tier 3: parking bans, traffic lights, local street features
/// Two signs at the same rank sort by distance.
int _signPriority(RoadSignKind k) => switch (k) {
  RoadSignKind.speed ||
  RoadSignKind.noPassing ||
  RoadSignKind.noPassingEnd => 0,
  RoadSignKind.stop ||
  RoadSignKind.giveWay ||
  RoadSignKind.tollBooth ||
  RoadSignKind.railwayCrossing ||
  RoadSignKind.tunnel ||
  RoadSignKind.endProhibitions ||
  RoadSignKind.slowDown => 1,
  RoadSignKind.noLeftTurn ||
  RoadSignKind.noRightTurn ||
  RoadSignKind.noUTurn ||
  RoadSignKind.noLeftUTurn ||
  RoadSignKind.noRightUTurn ||
  RoadSignKind.noTurnBoth ||
  RoadSignKind.noStraight ||
  RoadSignKind.onlyStraight ||
  RoadSignKind.onlyLeft ||
  RoadSignKind.onlyRight ||
  RoadSignKind.oneWay ||
  RoadSignKind.reservedLane ||
  RoadSignKind.noAuto ||
  RoadSignKind.noMoto => 2,
  RoadSignKind.noParking || RoadSignKind.signal => 3,
};

/// Pick the SINGLE most important sign from route-ahead signs (cấm vượt /
/// cấm rẽ / quay đầu first, then STOP / nhường đường) — the widget shows
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
/// DRIVING IMPORTANCE first (cấm vượt / cấm rẽ / quay đầu → STOP / nhường
/// đường → rest), then distance — so cấm vượt and the turn prohibitions always
/// appear ahead of a nearer but less critical sign.
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
