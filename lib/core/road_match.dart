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
