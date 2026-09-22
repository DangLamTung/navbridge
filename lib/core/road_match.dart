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

  String? get pending => _pending;
  int get confirmations => _count;

  /// Feed one proposal. Returns true when the change should be published.
  bool accept({
    required String current,
    required String candidate,
    required double movedM,
  }) {
    if (candidate == current) {
      reset();
      return false;
    }
    if (_pending != candidate) {
      _pending = candidate;
      _count = 1;
      _moved = movedM;
      return false;
    }
    _count++;
    _moved += movedM;
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
  }
}
