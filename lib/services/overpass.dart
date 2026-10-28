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
import 'offline_road_signs.dart' show kVnMaxPostedKmh;
import 'offline_speed_limits.dart' show streetNameMatches;
import 'urban_area.dart';

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

  /// WHERE [speedLimit] came from, for the widget's source badge:
  ///   'segment'  the Waze/WME per-segment posted limit under the car
  ///   'waze'     a Waze posted-limit POINT
  ///   'vietmap'  a VietMap E-DOG posted-limit point
  ///   'osm'      the OSM `maxspeed` tag on the way
  ///   'city'     statutory value chosen by the POI-density built-up test
  ///   'class'    statutory class default (no posted data at all)
  final String src;

  /// True when the value came from the built-up ("khu đông dân cư") rule: the
  /// POI-density test said this is a town AND nothing was posted, so the limit
  /// is the road-FORM one (50 hai chiều / 60 đường đôi) instead of the class
  /// default — which is a RURAL figure (mô tô primary/tertiary = 60).
  ///
  /// Logged per fix so a recorded drive can be audited against the vehicle
  /// class law afterwards: class + vehicle + oneway/lanes/divided + urban is
  /// the complete set of inputs [effectiveLimit] used.
  final bool urban;

  /// Whether the road FORM (oneway / lanes / divided) is genuinely known for
  /// this street (e.g. from OSM tags), rather than guessed or inherited from a
  /// previous road. When false, the vehicle zone ceiling applies instead of
  /// assuming a two-way road.
  final bool formKnown;

  /// True for the three posted-limit LAYER sources. While this is true the
  /// layer is authority: a speed sign may only tighten the limit, never raise
  /// it — see [signLimitInForce].
  bool get fromLayer => src == 'segment' || src == 'waze' || src == 'vietmap';

  RoadInfo({
    required this.name,
    required this.highway,
    this.maxspeed,
    required this.label,
    required this.speedLimit,
    this.oneway,
    this.lanes,
    this.divided = false,
    this.urban = false,
    this.src = 'class',
    this.formKnown = true,
  });

  /// Same road, a couple of fields replaced. Use this instead of re-listing
  /// every field: the hand-written copies had to be updated whenever a field
  /// was added, and silently dropped the new one when they weren't.
  RoadInfo copyWith({
    String? name,
    String? highway,
    String? maxspeed,
    String? label,
    int? speedLimit,
    bool? oneway,
    int? lanes,
    bool? divided,
    bool? urban,
    String? src,
    bool? formKnown,
  }) => RoadInfo(
    name: name ?? this.name,
    highway: highway ?? this.highway,
    maxspeed: maxspeed ?? this.maxspeed,
    label: label ?? this.label,
    speedLimit: speedLimit ?? this.speedLimit,
    oneway: oneway ?? this.oneway,
    lanes: lanes ?? this.lanes,
    divided: divided ?? this.divided,
    urban: urban ?? this.urban,
    src: src ?? this.src,
    formKnown: formKnown ?? this.formKnown,
  );
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
  'living_street' => ('', 50),
  'service' => ('', 50),
  'pedestrian' => ('', 50),
  'footway' => ('', 50),
  'cycleway' => ('', 50),
  'path' => ('', 50),
  'track' => ('Đường đất', 50),
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
  bool urban = false,
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
    'living_street': 50,
    'service': 50,
    'pedestrian': 50,
    'footway': 50,
    'cycleway': 50,
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
    'living_street': 50,
    'service': 50,
    'pedestrian': 50,
    'footway': 50,
    'cycleway': 50,
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
    'living_street': 40,
    'service': 40,
    'pedestrian': 40,
    'footway': 40,
    'cycleway': 40,
  };
  final table = switch (vehicle) {
    'motorbike' => motorbike,
    'truck' => truck,
    _ => car,
  };
  final base = table[highway] ?? 50;
  // Outside a built-up area a mô tô gets 70 on a divided road / one-way with
  // two motor lanes (Thông tư 38/2024). The class table above only carries the
  // two-way 60, and [vehicleCeiling] was applied solely to POSTED layer values,
  // so an untagged divided QL still showed 60. Only through-road classes take
  // the 70; ramps and service/residential streets keep their stricter class
  // value.
  if (!urban &&
      vehicle == 'motorbike' &&
      const {'trunk', 'primary', 'secondary', 'tertiary'}.contains(highway) &&
      dividedForm(divided: divided, oneway: oneway, lanes: lanes)) {
    return math.max(base, 70);
  }
  // Inside a built-up area the limit is set by the road's FORM, not its class
  // (Thông tư 38/2024/TT-BGTVT): đường đôi / một chiều từ hai làn = 60, đường
  // hai chiều / một làn = 50 (ô tô, mô tô); xe tải 50/40. `urban` comes from
  // the POI-density test in urban_area.dart — NOT from the removed boundary
  // signs. Cao tốc and the non-motor classes keep their own stricter value,
  // and this branch is only reached when nothing is posted (a tagged maxspeed
  // or a Waze segment value always wins).
  if (urban) {
    switch (highway) {
      case 'motorway':
      case 'motorway_link':
        return base;
    }
    // …and the built-up rule may only ever TIGHTEN, never raise: a ramp
    // (`trunk_link` / `primary_link` / `secondary_link`) carries a class
    // default of 50, and returning the đường-đôi 60 for it made a town ramp
    // read HIGHER than the same ramp in open country (found 2026-09-28 by the
    // invariant in test/services/urban_limit_change_test.dart). Entering a
    // built-up area must never tell the driver they may go faster.
    return math.min(
      base,
      urbanLimit(
        vehicle: vehicle,
        oneway: oneway,
        lanes: lanes,
        divided: divided,
      ),
    );
  }
  // `residential` / `unclassified` are built-up street classes by definition,
  // so the "khu đông dân cư" rule applies whether or not the POI test agreed:
  // đường đôi / một chiều ≥2 làn → 60, hai chiều → 50. Higher classes keep the
  // class default (their limit depends on urban/rural), and living_street /
  // service keep their stricter value.
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

/// Effective speed limit for [vehicle] on [highway], given an optional posted
/// value ([taggedKmh], 0 = nothing posted).
///
/// The sources, most trustworthy first (see [postedSrc]):
///   1. Waze per-SEGMENT posted limit (a sign keyed to the stretch of road)
///   2. Waze / VietMap posted-limit POINTS
///   3. the app's own built-up road-FORM rule (đường đôi 60 / hai chiều 50)
///   4. the statutory class default
///   5. an OSM `maxspeed` TAG — LAST.
///
/// A layer value is the authority for every vehicle, capped ONLY by the
/// vehicle's own legal maximum in this context ([vehicleCeiling]) — the road
/// class plays no part when the layer has spoken. Lũy Bán Bích, 2026-09-22: the
/// layer posts 60 on every segment of the street while OSM tags the first half
/// `residential` two-way, and min(default 50, posted 60) showed 50 for 59 fixes
/// of a 60 road; on 56 recorded drives 103 fixes had a real Waze 50/60 clamped
/// to 30 because the way under the car was classed `service`.
///
/// An OSM maxspeed TAG is different, and last: in Việt Nam it is sparse, often
/// stale and car-oriented. For a motorbike / truck it may only TIGHTEN our own
/// value — never set or raise it. (A car has no other posted source, so there
/// the tag IS the limit.)
int effectiveLimit(
  String highway, {
  required String vehicle,
  int taggedKmh = 0,
  bool? oneway,
  int? lanes,
  bool divided = false,
  bool urban = false,
  String postedSrc = srcOsm,
  bool formKnown = true,
}) {
  final statutory = statutoryLimit(
    highway,
    vehicle: vehicle,
    oneway: oneway,
    lanes: lanes,
    divided: divided,
    // A posted value IS the authority; the built-up rule only fills the gap
    // when nothing is posted (taggedKmh == 0).
    urban: urban && taggedKmh <= 0,
  );
  if (taggedKmh <= 0) return statutory;
  if (vehicle == 'car') {
    // A car has no other posted source, so the tag IS the limit — but the tag
    // can be junk: the shipped Waze layer carries 130 and 140 km/h segments on
    // roads where 90 is legal, and those became illegal advice on QL1. The
    // national maximum for any road is 120, so clamp there.
    //
    // NOT clamped to the 90/80 car rows: an expressway legitimately allows 120,
    // and vehicleCeiling returns a flat 120 for cars (it has no expressway
    // signal), so tightening it blindly would suppress a correct limit.
    return math.min(taggedKmh, kVnMaxPostedKmh);
  }
  if (postedSrc == srcOsm) {
    // Last place: the tag may still make the driver slower, never faster.
    return math.min(statutory, taggedKmh);
  }
  // Waze/VietMap 90 on a through road is evidence of a divided carriageway
  // even when the OSM/graph shape still says two-way (see applyPostedLayer).
  final postedDivided =
      vehicle == 'motorbike' &&
      postedSrc != srcOsm &&
      taggedKmh >= 90 &&
      _throughOrUnknown(highway);
  final postedAboveUrban =
      postedSrc != srcOsm && taggedKmh > 60 && _throughOrUnknown(highway);
  // ⭐ A layer value is a CAR limit, so the one thing a mô tô may read from it is
  // the road FORM. Điều 8 TT31/2019, outside a built-up area: ô tô 80 on a
  // two-way road with no median, 90 on a divided one — so a 65-85 value is a
  // TWO-WAY road, where a mô tô is 60. 70 is a divided-road number and must not
  // be handed to a bike (user, 2026-10-24: "waze nó kêu 70 tức là tốc độ chỗ đó
  // ô tô 70 … xe máy phải là 60 chứ đéo phải 70"). Without this a 70 came out as
  // 70 whenever the shape read one-way — which is EVERY divided carriageway, and
  // the graph encodes a divided road exactly that way.
  //
  // A road whose DIVISION is actually evidenced ([divided]: an opposite-way
  // carriageway of the same street runs alongside) keeps the 70: there the bike
  // really may do 70. Only the one-way GUESS loses. The road CLASS plays no part
  // — the value itself says this is a rural through road, which is also the case
  // when no road lookup has answered yet (`highway` is '' then, and the zone
  // ceiling below would otherwise hand the bike a car's 70).
  final carTwoWayRoad =
      vehicle == 'motorbike' &&
      postedSrc != srcOsm &&
      taggedKmh >= 65 &&
      taggedKmh < 90 &&
      !divided;
  // …and the mirror case IN TOWN is deliberately NOT derived from the layer: a
  // town 60 could be a đường-đôi value or a posted 60 sign on a hai-chiều
  // street, and the layer may only ever TIGHTEN a non-car class (see the
  // 103 measured fixes on 56 recorded drives). The side-of-road rule is what
  // fixes a wrong 60/50 pairing in town — see
  // [signedLateralOffsetMeters]: the opposite carriageway's sign is not ours.
  final urbanForCeiling = (postedDivided || postedAboveUrban) ? false : urban;
  final ceiling = formKnown
      ? vehicleCeiling(
          vehicle,
          urban: urbanForCeiling,
          divided: divided || postedDivided,
          oneway: oneway,
          lanes: lanes,
        )
      : vehicleZoneCeiling(vehicle, urban: urbanForCeiling);
  final capped = math.min(ceiling, taggedKmh);
  return carTwoWayRoad ? math.min(capped, 60) : capped;
}

/// The vehicle's absolute legal MAXIMUM in [urban] / rural zone regardless of
/// road form — Thông tư 38/2024. Used when the road form is unknown (e.g. when
/// the layer adopts a new street name) so a valid divided-road posted limit
/// (e.g. 60 in town for motorbike) is not clamped by a two-way assumption.
int vehicleZoneCeiling(String vehicle, {bool urban = false}) {
  switch (vehicle) {
    case 'motorbike':
      return urban ? 60 : 70;
    case 'truck':
      return urban ? 50 : 70;
    default:
      return kVnMaxPostedKmh;
  }
}

/// Is this a "đường đôi" (two carriageways / một chiều có từ hai làn xe cơ
/// giới)? The ONE definition of the road FORM — the built-up rule
/// ([urbanLimit]) and the vehicle ceiling ([vehicleCeiling]) must agree on it,
/// or a value the built-up rule calls 60 gets capped by a ceiling that thinks
/// the road is two-way. "Đường đôi" = two carriageways split by a dải phân
/// cách; OSM carries no median tag in VN, so the usable signals are [divided]
/// (an opposite-way carriageway of the same street sits alongside) and a
/// one-way way that itself carries ≥2 motor lanes ([oneway] + [lanes]).
///
/// A DIRECT one-way 1-lane tag OUTRANKS the [divided] inference. TT38/2024
/// names "đường một chiều một làn" as its own 50 case, and [divided] is only
/// INFERRED (an opposite way of the same street runs alongside), so it fires
/// falsely on parallel streets — and a mid-street flip of an inference must
/// never outvote a tag. Recorded on Đường Tôn Thất Hiệp: fixes 165-182 read
/// two-way / 2 lanes and showed 50, then fixes 183-206 flipped to
/// oneway + 1 lane + divided and jumped to 60 on the SAME street.
bool dividedForm({bool divided = false, bool? oneway, int? lanes}) {
  if (oneway == true && lanes == 1) return false;
  return divided || (oneway == true && (lanes ?? 2) >= 2);
}

/// Is the road FORM genuinely known from these fields, or are they defaults?
///
/// [dividedForm] cannot answer this: `false` is both "inferred two-way" and "we
/// were never told", and the same is true of a null `oneway` / `lanes`. The ONE
/// place that distinction is made, so [roadInfoFromRoad], the replay publisher
/// and [applyPostedLayer] cannot drift apart.
///
/// It matters because a *guess* at the form is not evidence: reading silence as
/// "hai chiều" caps a mô tô at 50 in town, and the shipped GraphHopper graph
/// encodes neither `oneway` nor `lanes` (see `tools/data/saigon_graph/properties`)
/// and sends no `divided` at all — so on the phone the form is UNKNOWN for every
/// road, and the zone ceiling (60 in town / 70 rural) is the honest answer.
bool formIsKnown({bool divided = false, bool? oneway, int? lanes}) =>
    divided || oneway != null || lanes != null;

/// One-way-ness from the routing graph's PER-DIRECTION car access.
///
/// This is the road FORM, and it is the thing the app could not know: the
/// phone's GraphHopper graph has no `oneway` and no `lanes` encoded value (see
/// `tools/data/saigon_graph/properties`), so every street read as "form unknown"
/// and the vehicle ceiling fell back to the ZONE ceiling — a legal 60 everywhere
/// in town, including genuine two-way streets where a mô tô may only do 50.
///
/// `car_access` IS stored for both directions, so:
///   * both directions open → a two-way street (`false` here, and thereafter
///     [formIsKnown] is true and the two-way 50 cap applies);
///   * exactly one open → a one-way way (`true`). In Việt Nam that means either
///     a genuine one-way street or ONE CARRIAGEWAY of a divided road — mappers
///     split those per direction, and [dividedForm] already reads a one-way way
///     as a đường đôi (≥2 làn), which is the 60 case. Verified against the
///     shipped graph with `tools/ProbeOneway.java`:
///       Lũy Bán Bích / Trường Chinh / Trần Quốc Hoàn  fwd=true  bwd=false
///       Đường 30 Tháng 4 / Cách Mạng / Âu Cơ             fwd=true  bwd=true
///   * NEITHER open → `null`: the graph is not describing a road the car may
///     use (prohibited / pedestrian), so the form stays unknown.
bool? onewayFromCarAccess({bool? forward, bool? backward}) {
  if (forward == null || backward == null) return null;
  if (forward != backward) return true;
  return forward ? false : null;
}

/// The vehicle's legal MAXIMUM speed given WHERE it is and WHAT the road is —
/// Thông tư 38/2024/TT-BGTVT (hiệu lực 01/01/2025):
///
///   xe mô tô ngoài khu đông dân cư: 70 trên đường đôi / một chiều ≥2 làn,
///                                   60 trên đường hai chiều (điển hình QL1A)
///   xe mô tô trong khu đông dân cư: 60 trên đường đôi, 50 trên đường hai chiều
///   xe tải  trong khu đông dân cư: 50 đường đôi / 40 hai chiều
///
/// The road FORM matters: 70 is not a mô tô limit, it is the divided-road
/// number. This used to return 70 for any road outside a built-up area, so a
/// Waze segment claiming 70 stood unchallenged on a two-way rural road where
/// the law says 60 — the clamp exists precisely to stop a layer value from
/// exceeding the law. Nothing a Waze sign says can legally put a mô tô above
/// this. Cars are uncapped here (the sign IS their limit).
///
/// An UNKNOWN form is read as the two-way case: most Vietnamese roads are, and
/// erring on the lower number can only make the driver slower.
int vehicleCeiling(
  String vehicle, {
  bool urban = false,
  bool divided = false,
  bool? oneway,
  int? lanes,
}) {
  final isDivided = dividedForm(divided: divided, oneway: oneway, lanes: lanes);
  switch (vehicle) {
    case 'motorbike':
      if (urban) return isDivided ? 60 : 50;
      return isDivided ? 70 : 60;
    case 'truck':
      // The rural pair is left as the class-level 60 until a road-form split
      // is verified for trucks.
      return urban ? (isDivided ? 50 : 40) : 60;
    default:
      return 120;
  }
}

/// True when the built-up ("khu đông dân cư") rule applies at [pos]: the road has
/// nothing posted, and the POI-density test says this is a town.
///
/// The ONE place this question is answered. It used to be re-derived separately
/// by the Overpass lookup, the on-device graph lookup and the standalone overlay
/// — the overlay's copy was missing it entirely, which is how it kept showing the
/// rural class default (60 on a 2-lane city street) after the app was fixed.
Future<bool> builtUpRuleApplies(LatLng pos, {required bool hasPosted}) async =>
    !hasPosted && await isUrbanArea(pos);

/// Provenance labels for [RoadInfo.src]. Use these instead of string literals so
/// a typo cannot silently disable the layer-authority rule ([RoadInfo.fromLayer]).
const String srcSegment = 'segment'; // Waze/WME per-segment posted limit
const String srcWazePoint = 'waze'; // Waze posted-limit point
const String srcVietmap = 'vietmap'; // VietMap E-DOG posted-limit point
const String srcOsm = 'osm'; // the way's own `maxspeed` tag
const String srcCity = 'city'; // built-up rule (POI density)
const String srcClass = 'class'; // statutory class default

/// Build the [RoadInfo] for a road from its OWN data (class + tags + form),
/// applying the statutory / built-up fallback.
///
/// Shared by every lookup path (Overpass, on-device graph, standalone overlay)
/// so the three cannot drift apart: they used to construct this independently,
/// which is why a rule fix had to be applied three times.
RoadInfo roadInfoFromRoad({
  required String name,
  required String highway,
  required String vehicle,
  int taggedKmh = 0,
  String? maxspeedTag,
  bool? oneway,
  int? lanes,
  bool divided = false,
  bool urban = false,
}) {
  final hasPosted = taggedKmh > 0;
  final statutory = statutoryLimit(
    highway,
    vehicle: vehicle,
    oneway: oneway,
    lanes: lanes,
    divided: divided,
    urban: urban,
  );
  // An OSM `maxspeed` tag is the LAST source we trust, so it may only be
  // reported as the source when it actually decided the number: a car takes the
  // tag as the limit, a motorbike/truck only when the tag is STRICTER than our
  // own rule. A tag our rule overrode must not put "osm" on the chip.
  final tagDecides = hasPosted && (vehicle == 'car' || taggedKmh < statutory);
  return RoadInfo(
    name: name,
    highway: highway,
    maxspeed: maxspeedTag,
    label: classInfo(highway).$1,
    speedLimit: effectiveLimit(
      highway,
      vehicle: vehicle,
      taggedKmh: taggedKmh,
      oneway: oneway,
      lanes: lanes,
      divided: divided,
      urban: urban,
    ),
    oneway: oneway,
    lanes: lanes,
    divided: divided,
    urban: urban,
    // A form the caller could not supply (the phone's graph carries neither
    // `oneway` nor `lanes`) is NOT a two-way road — see [formIsKnown].
    formKnown: formIsKnown(divided: divided, oneway: oneway, lanes: lanes),
    // Otherwise the value is ours: the built-up road-form rule, or the class
    // default outside a built-up area.
    src: tagDecides ? srcOsm : (urban ? srcCity : srcClass),
  );
}

/// The road FORM a step's own tags describe, when there is nothing posted on
/// it: the object a posted-limit layer is then applied to ([applyPostedLayer]).
///
/// ONE constructor, on purpose. Built inline, this object silently takes
/// `RoadInfo`'s `src` default — 'class' — which is how the replay published
/// every in-town street as CLASS (the RURAL statutory table) while the
/// layer-correction writer labelled the same street CITY, so the badge
/// alternated CITY/CLASS on a street that never changed (user, 2026-10-13: "why
/// city and class jumping, u forgot what is city?"). 89 recorded device drives
/// hold 3 071 `city` fixes and ZERO in-town `class` ones, so the device never
/// showed it — only the sim did.
///
/// [label] is passed through rather than derived, so a caller that shows the raw
/// OSM class on the chip (the replay does) keeps doing so while the live paths
/// keep using [classInfo].
RoadInfo statutoryRoad({
  required String name,
  required String highway,
  required String vehicle,
  required String label,
  bool? oneway,
  int? lanes,
  bool divided = false,
  bool urban = false,
}) => RoadInfo(
  name: name,
  highway: highway,
  label: label,
  oneway: oneway,
  lanes: lanes,
  divided: divided,
  urban: urban,
  // Nothing was posted, so the form is known only as far as the tags go —
  // a null `oneway`/`lanes` is "we were never told", not a two-way road.
  formKnown: formIsKnown(divided: divided, oneway: oneway, lanes: lanes),
  speedLimit: effectiveLimit(
    highway,
    vehicle: vehicle,
    oneway: oneway,
    lanes: lanes,
    divided: divided,
    urban: urban,
  ),
  // Which TABLE produced that number: the built-up rule in town, else the class
  // default (the rural one).
  src: urban ? srcCity : srcClass,
);

/// Map the PLATFORM CHANNEL's `roadInfo` map (GraphHopper, Kotlin) to a
/// [RoadInfo]. Null when the map carries no road class.
///
/// ONE place, because there are TWO consumers — the nav page
/// (`_roadInfoFromGraph`) and the standalone floating widget
/// (`overlay_main.dart`) — and each parsed the map by hand. The overlay already
/// drifted once (it re-derived the fallback and kept the RURAL class default in
/// town while the app showed 50), and they would have drifted again the moment
/// the form became knowable: the graph reports no `oneway` EV, so only the
/// per-direction car access says whether the road is a đường đôi.
RoadInfo? roadInfoFromGraphMap(
  Map<String, dynamic> g, {
  required String vehicle,
  required bool urban,
}) {
  final highway = (g['highway'] ?? '') as String;
  if (highway.isEmpty) return null;
  // GraphHopper sends Infinity for `maxspeed=none` — treat any non-finite value
  // as "no tagged limit" and fall back to the statutory class default. Also
  // reject implausible finite readings: a mis-decoded max_speed edge once turned
  // a real 50 km/h limit into a bogus "31".
  final msRaw = g['maxspeed'];
  final ms = (msRaw is num && msRaw.isFinite && msRaw >= 5 && msRaw <= 200)
      ? msRaw.toInt()
      : null;
  return roadInfoFromRoad(
    name: (g['name'] ?? '') as String,
    highway: highway,
    vehicle: vehicle,
    taggedKmh: ms ?? 0,
    maxspeedTag: ms == null ? null : '$ms',
    // An explicit `oneway` tag wins if a graph ever carries one; the shipped
    // graph has none, so the per-direction access IS the form (see
    // [onewayFromCarAccess] — verified against the real graph).
    oneway:
        parseOneway(g['oneway'] as String?) ??
        onewayFromCarAccess(
          forward: g['car_access_fwd'] as bool?,
          backward: g['car_access_bwd'] as bool?,
        ),
    lanes: parseLanes(g['lanes']),
    divided: g['divided'] == true,
    urban: urban,
  );
}

/// Apply a posted-limit LAYER value (Waze segment / Waze point / VietMap point)
/// to [road].
///
/// The layer is the authority for the limit (see [effectiveLimit]); the OSM
/// `maxspeed` TAG is the last source we trust, and it is car-oriented: for a
/// motorbike / truck it may only tighten the value our own rule produced.
/// [name] is optional — the layer often carries a better street name than the
/// graph/OSM way does.
/// Classes that are never a through road: a 90 km/h record on one of these is
/// data noise, not evidence of a divided carriageway.
const Set<String> _nonThroughHighway = {
  'residential',
  'service',
  'living_street',
  'footway',
  'cycleway',
  'path',
  'pedestrian',
  'track',
  'steps',
  'construction',
  'bus_stop',
};
// NOTE: `unclassified` is deliberately NOT in the list — it is a public
// through-capable road in OSM terms, and the graph labels real arterials that
// way (Phạm Văn Đồng came back `unclassified`).

/// Is [highway] a through road — or not known at all?
///
/// ⭐ The "unknown" half is the point. Every layer-evidence rule below (a posted
/// 70/80/90 proves the place is not built-up; a 90 proves a divided road) used
/// to require one of trunk/primary/secondary/tertiary. But `highway` is EMPTY
/// whenever no road lookup has answered — and on the 2026-10-25 drive that was
/// most of the way: the layer answered from the first fix while the graph/OSM
/// name did not, so a real Waze 90 was capped at the two-way 60 (or even the
/// town 50) for kilometres. Measured: 1,5 % of the trip sat 10–20 km/h below the
/// posted value exactly at Phạm Văn Đồng / Võ Nguyên Giáp / Xa lộ Hà Nội / QL1,
/// every one of them with `highway` empty (tool/waze_mod_sim.py, 2026-10-28).
bool _throughOrUnknown(String highway) =>
    highway.trim().isEmpty || !_nonThroughHighway.contains(highway.trim());

RoadInfo applyPostedLayer(
  RoadInfo road, {
  required int kmh,
  required String vehicle,
  required String layerSrc,
  String? name,

  /// Is the CAR in a built-up area (see [builtUpRuleApplies])? The vehicle
  /// ceiling needs that, but [RoadInfo.urban] cannot answer it: it is false by
  /// definition whenever the way carries an OSM `maxspeed` tag — even in the
  /// middle of a city — because there the tag replaces the built-up default.
  /// Null → fall back to [RoadInfo.urban].
  bool? inTown,
}) {
  final hasName = name != null && name.trim().isNotEmpty;
  final sameRoad =
      !hasName ||
      road.name.trim().isEmpty ||
      streetNameMatches(road.name, name);

  // The road form (oneway / lanes / divided) is only genuinely known when the
  // road tags came from the graph/OSM for THIS street. If the road was
  // synthesized from a layer rename, or if this call introduces a new street
  // name, the previous road's form must not bleed over.
  //
  // ⭐ [RoadInfo.formKnown], not `!road.fromLayer`. The two publishers of a
  // limit hand this function DIFFERENT objects for the same street:
  // `_withPostedLayer` passes the graph's road, `_correctSpeedFromWazeInner`
  // passes the road it last published (whose `src` is the layer's). The old
  // provenance test read that as "form known" for one and "form unknown" for
  // the other, so the SAME street got two different ceilings — 50 from the
  // road refresh (two-way assumption) and 60 from the layer correction (zone
  // ceiling) — and, publishing one after the other, they alternated on every
  // fix. Measured on the 2026-10-13 08:28 drive: 38 transitions 60↔50 over
  // 1.0 km on Lũy Bán Bích, whose Waze layer says 60 on every fix. The ceiling
  // is a property of the ROAD, so it must not depend on which object the
  // caller happens to be holding.
  final formGenuinelyKnown =
      sameRoad && road.name.trim().isNotEmpty && road.formKnown;

  // ⭐ A Waze/motorway-free segment posting 90 is EVIDENCE of a divided road.
  // In Việt Nam 90 km/h is the car limit on a divided road outside a built-up
  // area; a two-way road without a median is 80. The GraphHopper graph often
  // lacks `lanes`, and OSM/VietMap can still describe an upgraded QL1 as a
  // two-way way long after the median was built — so letting that stale form
  // cap a Waze 90 at the mô tô two-way 60 was wrong. Only through-road classes
  // and only 90+ (not a generic 60/70/80) are treated as this evidence.
  final fastDivided =
      vehicle == 'motorbike' && kmh >= 90 && _throughOrUnknown(road.highway);
  // Any posted limit above the urban maximum (60) is proof the place is NOT
  // built-up: 70/80/90 are rural limits. The POI/road-density probe can call a
  // highway outside Dầu Giây “urban” because many Waze segments surround it —
  // that must not cap a real 70/80/90 to the town table.
  final postedAboveUrban =
      layerSrc != srcOsm && kmh > 60 && _throughOrUnknown(road.highway);
  // Use the posted limit only to choose the CEILING; do not rewrite the
  // zone flag itself. A 70/80/90 is not a legal town limit, so it must not be
  // capped by a false-positive urban probe, but calling the whole place rural
  // is a separate claim this function is not entitled to make.
  final ceilingUrban = (fastDivided || postedAboveUrban)
      ? false
      : (inTown ?? road.urban);

  // ⭐ The same car-value-as-FORM evidence as [effectiveLimit] — this is the
  // path the road chip actually takes (every posted layer value), so the two
  // must agree or the dial and the callout disagree.
  //
  // 65-85 outside town: the car row there is 80 (hai chiều) / 90 (đường đôi),
  // so 70 is a TWO-WAY value ⇒ mô tô 60 (user, 2026-10-24: "waze nó kêu 70 …
  // xe máy phải là 60 chứ đéo phải 70"). A road whose median is actually
  // evidenced (`road.divided`) keeps its 70 — only the one-way GUESS at the
  // form loses.
  final carTwoWayRoad =
      vehicle == 'motorbike' &&
      layerSrc != srcOsm &&
      kmh >= 65 &&
      kmh < 90 &&
      !road.divided;

  final int ceiling;
  if (formGenuinelyKnown) {
    ceiling = vehicleCeiling(
      vehicle,
      urban: ceilingUrban,
      divided: road.divided || fastDivided,
      oneway: road.oneway,
      lanes: road.lanes,
    );
  } else {
    // When road form is unknown from OSM or adopting a new road name from layer:
    // use the vehicle zone ceiling (60 in town, 70 rural for motorbikes)
    // so valid divided-road posted limits (60 on Lũy Bán Bích, Trường Chinh)
    // are not clamped by a two-way assumption.
    ceiling = vehicleZoneCeiling(vehicle, urban: ceilingUrban);
  }

  final effective = vehicle == 'car'
      ? math.min(kmh, kVnMaxPostedKmh)
      : carTwoWayRoad
      ? math.min(math.min(ceiling, kmh), 60)
      : math.min(ceiling, kmh);

  final newDivided = sameRoad ? (road.divided || fastDivided) : fastDivided;

  return RoadInfo(
    name: hasName ? name : road.name,
    highway: road.highway,
    maxspeed: '$kmh',
    label: road.label.isNotEmpty ? road.label : classInfo(road.highway).$1,
    speedLimit: effective,
    oneway: road.oneway,
    lanes: road.lanes,
    divided: newDivided,
    urban: inTown ?? road.urban,
    // ⭐ Carry the form's provenance through, not just the form. Without this
    // the value we just published goes back to `formKnown: true` (the field's
    // default), so the NEXT application for the same street would re-classify
    // the road as a known two-way and clamp it back — the same 60/50 flap from
    // the other direction. A road whose form we did not know still has an
    // unknown one afterwards (and a road we renamed knows nothing about the
    // new name's form at all — see `newDivided`).
    formKnown: formGenuinelyKnown,
    // The posted-limit layer has now spoken: from here a speed sign may only
    // tighten this value (see [signLimitInForce]).
    src: layerSrc,
  );
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
  final isDivided = dividedForm(divided: divided, oneway: oneway, lanes: lanes);
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
  final tagged = _effectiveMaxspeed(tags);
  final taggedKmh = tagged == null ? 0 : parseMaxspeed(tagged, 0);
  final oneway = parseOneway(tags['oneway'] as String?);
  final lanes = parseLanes(tags['lanes']);
  // "Đường đôi" detection: another way of the SAME street running roughly the
  // opposite way, close enough to be the other carriageway of a dải phân cách.
  final divided = _hasOppositeCarriageway(pos, best, pool);
  // Nothing tagged → decide the urban table from POI density, so a class
  // default meant for the countryside (primary = 80/60) does not stand inside
  // a town (50, or 60 on a divided road).
  final urban = await isUrbanArea(pos);
  // One constructor for every lookup path — see [roadInfoFromRoad].
  final info = roadInfoFromRoad(
    name: (tags['name'] ?? '') as String,
    highway: highway,
    vehicle: vehicle,
    taggedKmh: taggedKmh,
    // The raw tag text is kept for the chip ("50", "50 km/h", …). `tagged`
    // prefers the plain `maxspeed`, then the directional / conditional variants
    // — `maxspeed:forward` is usually a superset on dual carriageways, but the
    // plain tag is the more reliable base value, so it wins when present.
    maxspeedTag: tagged,
    oneway: oneway,
    lanes: lanes,
    divided: divided,
    urban: urban,
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
