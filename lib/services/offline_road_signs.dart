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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:latlong2/latlong.dart';

import '../core/nav_protocol.dart' show formatDistanceSpoken;
import 'offline_geo.dart';
import 'offline_loader.dart';
import 'offline_scan.dart';
import 'offline_scan_isolate.dart';

/// The kind of road sign — drives the map icon and the spoken warning.
///
/// Every label carries the QCVN 41 code OF THE BUNDLED PNG
/// (`lib/ui/sign_icons.dart`), so the code in the info sheet can never
/// contradict the picture: P.124a cấm quay đầu (was mislabelled P.125 — which is
/// the overtaking ban), P.125 cấm vượt (was P.127), R.301a/d/e chỉ được đi
/// thẳng / rẽ phải / rẽ trái (was R.411/R.412 — those are lane-direction boards).
///
/// The built-up boundary ("bắt đầu / hết khu đông dân cư") IS loaded: the
/// driver asked to hear it ("Bắt đầu khu dân cư / Hết khu dân cư") and the two
/// kinds carry real data — 4 685 starts + 4 526 ends, 103 of them within 100 m
/// of the recorded 1 690 km Hà Nội → Sài Gòn drive. What they must NOT do is
/// set the speed limit; see [droppedSignKinds].
enum RoadSignKind {
  stop('stop', 'P.122 Biển STOP'),
  giveWay('giveWay', 'Biển nhường đường'),
  speed('speed', 'Hạn chế tốc độ'),
  signal('signal', 'Đèn giao thông'),
  noPassing('no_passing', 'P.125 Cấm vượt'),
  noPassingEnd('no_passing_end', 'P.133 Hết cấm vượt'),
  noLeftTurn('no_left_turn', 'P.123 Cấm rẽ trái'),
  noRightTurn('no_right_turn', 'P.124 Cấm rẽ phải'),
  noUTurn('no_u_turn', 'P.124a Cấm quay đầu'),
  noLeftUTurn('no_left_uturn', 'P.124c Cấm rẽ trái và quay đầu'),
  noRightUTurn('no_right_uturn', 'P.124d Cấm rẽ phải và quay đầu'),
  onlyStraight('only_straight', 'R.301a Chỉ được đi thẳng'),
  onlyLeft('only_left', 'R.301e Chỉ được rẽ trái'),
  onlyRight('only_right', 'R.301d Chỉ được rẽ phải'),
  endProhibitions('end_prohibitions', 'P.135 Hết mọi lệnh cấm'),
  slowDown('slow_down', 'Giảm tốc độ'),
  noAuto('no_auto', 'P.103a Cấm ô tô'),
  noMoto('no_moto', 'P.104 Cấm xe máy'),
  oneWay('one_way', 'I.407a Đường một chiều'),
  noStraight('no_straight', 'P.136 Cấm đi thẳng'),
  noTurnBoth('no_turn_both', 'P.137 Cấm rẽ trái và rẽ phải'),
  reservedLane('reserved_lane', 'Làn dành riêng'),
  noParking('no_parking', 'P.131a Cấm đỗ xe'),
  tollBooth('toll_booth', 'Trạm thu phí'),
  railwayCrossing('railway_crossing', 'W.242a Đường ngang giao với đường sắt'),
  tunnel('tunnel', 'W.240 Hầm đường bộ'),

  // Khu đông dân cư boundaries (QCVN R.420 / R.421). Loaded, DRAWN and
  // ANNOUNCED — but they never set a speed limit (see [droppedSignKinds]).
  populated('populated', 'Bắt đầu khu đông dân cư'),
  populatedEnd('populated_end', 'Hết khu đông dân cư');

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

/// JSON `kind` values that are DROPPED at load time — **now empty**.
///
/// It used to contain `populated` / `populated_end` (the "bắt đầu / hết khu
/// đông dân cư" boundaries: 4 685 starts + 4 526 ends from VietMap E-DOG
/// TYPE 9/10, Waze and OSM). They were dropped for what they COST, not because
/// the data is wrong (measured by `tool/why_drop_kdc.py`):
///  * a third LIMIT source (a built-up cap) that cannot be validated from a
///    recording — on 38 recorded drives not one boundary point came within
///    200 m of the track, so the cap never fired and never got checked;
///  * where one does sit on a Waze/WME segment that segment posts more than the
///    cap 39 % of the time, so when it fires it overrides a posted value.
///
/// Both reasons are about the LIMIT, and neither survives contact with the long
/// drive (103 boundary points within 100 m of the recorded 1 690 km Hà Nội →
/// Sài Gòn track). So the kinds are back — announced and drawn — while the
/// built-up decision stays with the density rule in `urban_area.dart`:
/// [RoadSign]s of these kinds are never read by `builtUpRuleApplies`.
///
/// Filtered HERE (not in the asset) so an already-downloaded
/// `vietnam_signs.json` from an older build stays usable.
const Set<String> droppedSignKinds = {};

const Set<RoadSignKind> zoneSignKinds = {
  RoadSignKind.tollBooth,
  RoadSignKind.noPassing,
  RoadSignKind.noPassingEnd,
  RoadSignKind.slowDown,
  RoadSignKind.tunnel,
  RoadSignKind.railwayCrossing,
  // The boundaries come out of the same VietMap E-DOG zone dump (TYPE 9/10) as
  // the kinds above, so their stored point may be a polygon vertex rather than
  // the post on the carriageway — announce the ZONE, never a distance to it.
  // (`tools/signs/snap_sign_roads.py` carries the same list as its POLICY so a
  // rebuild can snap them onto the road.)
  RoadSignKind.populated,
  RoadSignKind.populatedEnd,
};

String signAheadTail(RoadSignKind kind, double meters) =>
    zoneSignKinds.contains(kind) ? '' : ' ${formatDistanceSpoken(meters)}';

/// Lateral tolerance for a normal road sign in the ahead scan, metres.
///
/// A sign POST stands on the carriageway; one 100 m to the side belongs to the
/// street it stands on (a parallel road / a crossing), so it is not "ahead on
/// this route".
const double kRoadsideLateralMeters = 40.0;

/// Lateral tolerance for [zoneSignKinds] in the ahead scan, metres.
///
/// 40 m is right for a POST on the carriageway — a sign 100 m away is another
/// street's. A zone-referenced kind is not a post: it is stored at an area
/// vertex, so the same 40 m silently dropped 140 of the 161 khu đông dân cư
/// boundaries that come within 150 m of the recorded 1 690 km Hà Nội → Sài Gòn
/// drive (measured 2026-09-28) — the boundary would have been announced at 1 in
/// 8 of the places the driver actually crosses one. 150 m is the corridor the
/// nav map already uses for its sign layer.
const double kZoneLateralMeters = 150.0;

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
  final rows = [
    for (final it
        in (data['signs'] as List? ?? const []).cast<Map<String, dynamic>>())
      if (!droppedSignKinds.contains(it['kind'])) RoadSign.fromJson(it),
  ];
  var coarse = 0;
  var impossible = 0;
  final kept = <RoadSign>[];
  for (final s in rows) {
    if (isImpossibleSpeedSign(s)) {
      impossible++;
      continue;
    }
    if (!signCoordsAreUsable(s)) {
      coarse++;
      continue;
    }
    kept.add(s);
  }
  if (coarse > 0) {
    debugPrint(
      'SIGNS: dropped $coarse sign(s) with coordinates too coarse to place '
      '(< $kMinSignDecimals decimals ≈ 111 m) — a cấm rẽ / chỉ rẽ sign that far '
      'off fires its warning on the wrong street',
    );
  }
  if (impossible > 0) {
    debugPrint(
      'SIGNS: dropped $impossible impossible speed value(s) '
      '(> $kVnMaxPostedKmh km/h)',
    );
  }
  return kept;
}

/// Decimal places a coordinate must carry to be worth trusting on the ground.
///
/// The feed stores whole KINDS on a coarse grid, measured over the bundled
/// index (2026-09-01, 45,197 signs, `tool/audit_turn_signs.py`):
///
/// ```
///   only_left          6/6     (100%)   no_right_turn     55/247   (22%)
///   only_right        11/11    (100%)   no_left_turn     122/353   (35%)
///   end_prohibitions 270/350   (77%)    no_u_turn         94/228   (41%)
///   only_straight      9/17    (53%)    speed          4,168/20,753 (20%)
///   every osm toll_booth / slow_down / tunnel / railway_crossing row  (100%)
/// ```
///
/// 3 decimals is a 0.001° grid ≈ 111 m, so the stored point can be ±55 m from
/// the sign (2 decimals ⇒ ±550 m). These are not silent: `nav_signs.dart`
/// SPEAKS them ("Cấm rẽ trái sắp tới", "Chỉ rẽ trái sắp tới"), so a sign half a
/// block away warns on the wrong street — and of the 8 turn signs within 1.5 km
/// of the Bàu Cát corridor, 5 had no second street (2 had no street at all)
/// within 30 m of their stored position. `populated`/`populated_end` were
/// dropped outright for exactly this kind of error — see [droppedSignKinds].
///
/// Kept as a LOAD guard so a downloaded/auto-updated index is filtered too.
const int kMinSignDecimals = 4;

/// True when a sign's stored coordinate is precise enough to place on the road.
///
/// The count is taken from the decoded double, so a genuine 4-decimal value
/// that happens to end in zeros (e.g. `106.6500`) reads as 3 and is dropped:
/// a fraction of a percent of the fine rows, traded against warnings that point
/// at the wrong street.
bool signCoordsAreUsable(RoadSign s) =>
    _decimals(s.lat) >= kMinSignDecimals && _decimals(s.lng) >= kMinSignDecimals;

int _decimals(double v) {
  final text = v.toString();
  final dot = text.indexOf('.');
  if (dot < 0) return 0;
  var n = text.length - dot - 1;
  // "1e-5" style output for very small values would collapse to 1 digit.
  if (text.contains('e') || text.contains('E')) return 9;
  while (n > 0 && text[text.length - 1] == '0') {
    n--;
  }
  return n;
}

/// The highest speed limit that can legally be posted in Việt Nam — 120 km/h,
/// on an expressway of 4+ lanes (Thông tư 38/2024).
const int kVnMaxPostedKmh = 120;

/// True when a row is physically impossible and must be DISCARDED at load.
///
/// The VietMap E-DOG feed carries 7 "Hạn chế tốc độ" signs of 135–157 km/h
/// (e.g. 11.132,107.731 → 157). They are not cosmetic: `nav_signs.dart` adopts
/// the nearest speed sign's value as the LIVE limit, so one of these can post a
/// 157 km/h limit on the dashboard, and the map draws a red circle reading 157.
/// Filtered HERE rather than in the asset so a downloaded
/// `vietnam_signs.json` from a future update cannot reintroduce them.
bool isImpossibleSpeedSign(RoadSign s) =>
    s.kind == RoadSignKind.speed &&
    s.value != null &&
    (s.value! <= 0 || s.value! > kVnMaxPostedKmh);

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
  double lateralMeters = kRoadsideLateralMeters,
}) async {
  return OfflineScanIsolate.instance.signsAhead(
    current,
    geometry,
    maxAheadMeters: maxAheadMeters,
    lateralMeters: lateralMeters,
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
  final span = maxDistM / kMetersPerDegLat;
  // Longitudes shrink with cos(lat); without this the bbox prunes signs that
  // are within range but due east/west (up to ~7% loss for Việt Nam).
  final lngSpan = maxDistM / metersPerDegLng(pos.latitude);
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
  final lat = (la1 - la2) * kMetersPerDegLat;
  final lng = (lo1 - lo2) * metersPerDegLng((la1 + la2) / 2);
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

/// Keep only the signs the driver has NOT passed yet.
///
/// A sign the car has gone by is behind it and no longer worth a marker — user,
/// 2026-09-24: "sign behind the car can be remove, but when turn back must show".
/// The test is against the CURRENT heading, not the route's stored order, which
/// is what makes the second half work for free: turn around (U-turn, a re-route,
/// or simply heading back down the same road) and the very same signs are in
/// front again, so they come straight back — no state to reset.
///
/// [keepBehindM] keeps a sign that is only just behind (the post you are passing
/// right now) so the icon does not blink out from under the car.
///
/// Only signs with a positive component ALONG the heading survive; a sign square
/// to the side (along ≈ 0) is kept while driving past it, and goes once the
/// heading itself turns away from it.
List<RoadSign> signsAheadOfDriver(
  List<RoadSign> signs, {
  required LatLng car,
  required double headingDeg,
  double keepBehindM = 40,
}) {
  final out = <RoadSign>[];
  for (final s in signs) {
    final along = alongHeadingMeters(car, LatLng(s.lat, s.lng), headingDeg);
    if (along >= -keepBehindM) out.add(s);
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
  // A built-up boundary changes which limit table applies, so it outranks any
  // turn prohibition when the console has to choose what to show.
  RoadSignKind.populated ||
  RoadSignKind.populatedEnd ||
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
