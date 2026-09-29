/// Deciding which STREET NAME to publish for a road match, and when to change it.
///
/// Why this exists: the road matcher resolves the car's road from geometry
/// alone, and on a recorded drive it picks a road that is not the one under the
/// car in ~48% of fixes (median 119 m away, when the correct way is 4 m away —
/// audited over the 2026-09-21 17:33 drive). The street name, the road class and
/// therefore the built-up 50/60 limit all follow that wrong road, which is what
/// the driver sees as a wrong street and a wrong limit at a junction.
///
/// Two cheap, local corrections, both using information we already have:
///   * the ROUTE is a veto — a name that appears on the route the car is
///     following outranks one that does not ([pickRoadName]);
///   * hysteresis — one odd match must not relabel the road and flip back
///     ([RoadNameHysteresis]); at a junction the match alternated every second
///     for 17 s.
library;

import 'package:navbridge/services/osm_api.dart' show removeDiacritics;

/// Comparison key for a street name: case, diacritics, punctuation and spacing
/// removed, so "Đường 30 Tháng 4" and "30 thang 4" compare as one road. The
/// route's step names, the graph's way names and the Waze segment names spell
/// the same street differently.
String roadKey(String name) =>
    removeDiacritics(name.toLowerCase()).replaceAll(RegExp('[^a-z0-9]'), '');

/// True when two names plausibly denote the same street — equal keys, or one
/// contains the other ("Vườn Lài" vs "Hẻm 4 Vườn Lài").
bool sameRoad(String a, String b) {
  final ka = roadKey(a), kb = roadKey(b);
  if (ka.isEmpty || kb.isEmpty) return false;
  return ka == kb || ka.contains(kb) || kb.contains(ka);
}

/// The name to publish for a matched road, with the route as a veto.
///
/// [candidateOnRoute] / [currentOnRoute] say whether each name appears among the
/// route's own names for where the car is (its current step and the two ahead).
String pickRoadName({
  required String current,
  required String candidate,
  required bool candidateOnRoute,
  required bool currentOnRoute,
}) {
  if (candidate.isEmpty) return current;
  if (candidateOnRoute) return candidate; // the match agrees with the route
  if (currentOnRoute) return current; // match is off-route, ours is not
  return candidate; // neither is on the route: trust the match
}

/// True when two names are the SAME spelling of the same road: identical keys,
/// so only case, diacritics, punctuation and spacing differ.
///
/// Distinct from [sameRoad], which also treats containment as one road. This is
/// the test for "is the label actually changing?": the 2026-09-22 20:54 drive
/// churned 'Cộng Hòa' ⇄ 'Cộng Hoà' for 54 s because the publisher compared the
/// strings with `!=` while the veto compared road keys — so a variant spelling
/// counted as a new road, was confirmed twice, and repainted the label.
bool sameRoadSpelling(String a, String b) {
  final ka = roadKey(a);
  return ka.isNotEmpty && ka == roadKey(b);
}

/// Whether a posted limit that came from a road segment may be adopted: the
/// segment's own street name (when it has one) must agree with the name we are
/// about to display. Name and limit must describe the SAME road.
///
/// Measured on the 2026-09-21 17:33 drive (tool/simulate_nav.py): the segment
/// layer disagreed with the settled road name on 26 fixes and its value changed
/// the chip's limit on 16 of them — the display said 'Lũy Bán Bích' while the
/// 50 km/h came from the crossing 'Độc Lập', and 'Thống Nhất' while the 60 came
/// from 'Lũy Bán Bích'. Only the NAME used to go through the veto in
/// [pickRoadName]; the limit travelled with the segment record.
///
/// An unnamed segment (62% of the layer) carries no evidence either way, so it
/// is allowed through.
bool postedLimitMatchesName(String? segmentName, String settledName) {
  if (segmentName == null || segmentName.isEmpty) return true;
  if (settledName.isEmpty) return true;
  return sameRoad(segmentName, settledName);
}

/// The same question with EVERY name we know for the road under the car.
///
/// [settled] is the name on screen (empty until a road lookup answers),
/// [osmName] the last OSM-tagged name, [routeNames] the route's own names here.
/// The segment's value is adopted if it agrees with ANY of them.
///
/// A veto needs something to veto against: when all three are empty the
/// segment is the only evidence there is, so its value is adopted. Refusing it
/// is how a 1,686 km drive down QL1A showed no limit at all while the pack knew
/// it within 25 m at 78 of its 79 sampled points (2026-09-27) — the road lookup
/// that would have named the road was failing (Overpass 504 on the web build,
/// offline graph elsewhere), and the layer was waiting for it.
bool layerLimitMatchesNames({
  required String? segmentName,
  required String settled,
  required String osmName,
  required Iterable<String> routeNames,
  bool ridden = false,
}) {
  if (segmentName == null || segmentName.isEmpty) return true; // 62% unnamed
  // ⭐ A segment the car is RIDING is evidence about the road UNDER it, whatever
  // name we happen to hold.
  //
  // Every rule below compares NAMES, so all of them can be defeated by one wrong
  // name — and the name they compare against is the road matcher's, which names
  // a road that is not the one under the car on ~48% of fixes (see the library
  // doc). Measured on the 2026-09-29 08:37 drive at the Trường Chinh turn: the
  // matcher held "Trương Công Định" (tertiary, 9.2 m, 83-128° across the car)
  // while the segment the car rode was Trường Chinh 60 (7.9 m, 1-11° along it),
  // so the value was refused and the dial showed the wrong road's 50 for 29
  // fixes — the device's own log (`limitLayer=segment`, 50 km/h, street "Trương
  // Công Định") is what proved it was not a simulator artefact.
  //
  // This does NOT reopen the case the check exists for. The check stops a segment
  // that runs ACROSS the car (a crossing street) from posting its value for our
  // road, and a crossing segment is by definition not riding-aligned — see
  // `SpeedLimitResult.aligned`, set from the same 45° test `segmentScore` uses.
  if (ridden) return true;
  if (settled.isNotEmpty && sameRoad(segmentName, settled)) return true;
  if (osmName.isNotEmpty && sameRoad(segmentName, osmName)) return true;
  // Only names that really are names: the caller must already have filtered
  // blanks and the engine's "carry on" placeholder with [routeRoadNames].
  final routes = routeNames.where((n) => n.trim().isNotEmpty);
  if (settled.isEmpty && osmName.isEmpty && routes.isEmpty) return true;
  return routes.any((n) => sameRoad(n, segmentName));
}

/// The route's three name slots, filtered to names worth comparing.
///
/// The engine fills a step with [placeholder] ("Tiến lên" — carry on straight)
/// when the step HAS no street name, and that placeholder is not a road. Passing
/// it in as a route name made every real street disagree with the route, so the
/// posted limit was dropped: measured on the 1,686 km QL1A fixture, the dial
/// read '-' on all 84,532 fixes while the offline segment pack held 60 under the
/// car. Blank slots are dropped for the same reason.
Set<String> routeRoadNames(
  Iterable<String?> slots, {
  String placeholder = '',
}) {
  final out = <String>{};
  for (final s in slots) {
    final t = (s ?? '').trim();
    if (t.isEmpty) continue;
    if (placeholder.isNotEmpty && t == placeholder) continue;
    out.add(t);
  }
  return out;
}

/// Hysteresis for a road-name change: the new name must be proposed
/// [confirmFixes] times, or the car must travel [confirmMeters] while it is
/// proposed, before it replaces the name on screen.
class RoadNameHysteresis {
  RoadNameHysteresis({this.confirmFixes = 2, this.confirmMeters = 30});

  /// Consecutive proposals needed to accept a change.
  final int confirmFixes;

  /// Metres of travel that force a change through (a real road change is
  /// covered quickly; a bad match at a junction is not).
  final double confirmMeters;

  String? _pending;
  int _count = 0;
  double _moved = 0;
  DateTime? _lastObsAt;

  String? get pending => _pending;
  int get confirmations => _count;

  /// Feed one proposal. Returns true when the change should be published.
  ///
  /// [at] is when the observation was made. Two writers publish a road on the
  /// same fix (the graph refresh and the layer correction), and if both propose
  /// the same name they would otherwise burn the whole confirmation budget
  /// inside ONE fix — which turns the hysteresis into a rename on every fix,
  /// i.e. exactly the flapping it exists to prevent. Observations closer
  /// together than [_minObservationGap] count once. Omitting [at] disables the
  /// guard (unit tests call it that way).
  bool accept({
    required String current,
    required String candidate,
    required double movedM,
    DateTime? at,
  }) {
    if (sameRoadSpelling(candidate, current)) {
      reset();
      return false;
    }
    if (_pending != candidate) {
      _pending = candidate;
      _count = 1;
      _moved = movedM;
      _lastObsAt = at;
      return false;
    }
    if (at != null &&
        _lastObsAt != null &&
        at.difference(_lastObsAt!).abs() < _minObservationGap) {
      return false; // the same fix, agreeing itself
    }
    _count++;
    _moved += movedM;
    _lastObsAt = at;
    if (_count >= confirmFixes || _moved >= confirmMeters) {
      reset();
      return true;
    }
    return false;
  }

  void reset() {
    _pending = null;
    _count = 0;
    _moved = 0;
    _lastObsAt = null;
  }

  /// Observations closer together than this are one observation.
  static const Duration _minObservationGap = Duration(milliseconds: 400);
}

/// The name to hand the posted-limit layer as `expectStreet` — the name that is
/// allowed to make the layer REJECT a segment whose own street disagrees.
///
/// Only a name the ROUTE confirms is trustworthy enough to veto with. The
/// matcher names a road that is not the one under the car on ~48% of fixes
/// (see [pickRoadName]), and vetoing with that wrong name makes the layer throw
/// away the segment that is really there — so the WRONG road's limit is adopted
/// and the chip never changes.
///
/// Measured on the 2026-09-29 drive: the car sat 2-24 m from **Trường Chinh**
/// (60 km/h) for 24 consecutive fixes while `expectStreet` was the crossing
/// **Trương Công Định**, pinning the answer to that road's 50 — and the layer's
/// own answer for the same fixes was Trường Chinh. The driver saw exactly that:
/// "trường chinh change too slow".
///
/// Returns the ROUTE's own current name when neither the OSM nor the shown name
/// is one the route knows — the route is the one source that says which road the
/// car is following. [routeCurrent] empty (and no confirmed name) returns '' i.e.
/// no veto: the layer is then free to answer, and [layerLimitMatchesNames] still
/// gates what comes back. An empty [routeNames] keeps the old behaviour — there
/// is nothing to compare against, so the OSM name stands.
String vetoStreetFor({
  required String osmName,
  required String shownName,
  required Iterable<String> routeNames,
  String routeCurrent = '',
}) {
  final names = [for (final n in routeNames) if (n.trim().isNotEmpty) n];
  if (names.isEmpty) {
    return osmName.trim().isNotEmpty ? osmName : shownName;
  }
  if (osmName.trim().isNotEmpty && names.any((n) => sameRoad(n, osmName))) {
    return osmName;
  }
  if (shownName.trim().isNotEmpty && names.any((n) => sameRoad(n, shownName))) {
    return shownName;
  }
  if (routeCurrent.trim().isNotEmpty) return routeCurrent;
  return '';
}
