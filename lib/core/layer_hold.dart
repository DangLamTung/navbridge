/// How long a POSTED-LIMIT LAYER value may outlive the lookup that produced it.
///
/// The layer (Waze WME segments → Waze points → VietMap points) answers with a
/// record within 25 m of the car. When it MISSES, the app holds the value
/// already on screen, because demoting to the road's statutory class default on
/// a single miss made the chip stutter at every junction where the segment layer
/// has a gap (measured: 30 same-road flips on the 2026-09-22 20:48 drive).
///
/// That hold used to have no end. It was written as "still on the SAME road",
/// tested with `sameRoad(cur.name, name)` — but on a miss there is no segment to
/// name the road, so `name` IS `cur.name` and the test could never fail. Once a
/// layer value was on screen it was kept through every miss, forever: driving
/// off the end of the layer's coverage kept the old number on the chip for the
/// rest of the drive (user, 2026-10-10: "move from 60 km have waze segment to no
/// waze segment still not correct, last trip still have the 60 even after moved
/// to new place").
///
/// So the hold is now bounded by DISTANCE DRIVEN since the layer last answered
/// for the road on screen. Distance and not time, because the hold exists to
/// bridge a few tens of metres of missing record: a car waiting at a light is
/// still on the same road, and its hold must not expire just because no fix
/// covered new ground.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'road_match.dart';

/// The bounded memory behind "may I keep showing the layer's value although the
/// lookup just missed?".
class LayerHold {
  LayerHold({this.maxMeters = 300});

  /// How far the car may drive after the layer last answered for the road on
  /// screen before the held value goes stale.
  ///
  /// Calibrated, not guessed: over 66 recorded drives (24k fixes) the longest
  /// hold the app legitimately needed — the layer had no record within 25 m but
  /// the car was still on the covered road, Lũy Bán Bích — was 145 m (p90 of the
  /// 45 held runs: 99 m, median 0 m). 300 m is twice that worst case, so no
  /// measured gap is broken, while a genuine move onto an uncovered road still
  /// releases the value within seconds of driving.
  ///
  /// It is a BACKSTOP, not the primary test: a car that changes road normally
  /// changes the road NAME too, and that already releases the hold (the road is
  /// re-resolved and published with the new road's own limit). This bound only
  /// catches the case where the name stays the same and the layer never answers
  /// again — the one that used to freeze the value for the rest of the drive.
  final double maxMeters;

  LatLng? _at;
  String _road = '';

  /// The layer just answered for [road] while the car was at [at].
  void note(String road, LatLng at) {
    _road = road;
    _at = at;
  }

  /// Drop the hold — a fresh navigation / simulation session, or a road the
  /// layer has nothing to say about at all.
  void forget() {
    _road = '';
    _at = null;
  }

  /// May the value held for [road] still be shown, with the car now at [at]?
  ///
  /// False when the layer never answered, when [road] is not the road that
  /// answer described, or when the car has driven past [maxMeters] since.
  bool fresh(String road, LatLng? at) {
    final held = _at;
    if (held == null) return false;
    if (!sameRoad(_road, road)) return false;
    if (at == null) return true;
    return _meters(held, at) <= maxMeters;
  }
}

double _meters(LatLng a, LatLng b) {
  final dLat = (b.latitude - a.latitude) * 111320.0;
  final cosLat = math.cos(a.latitude * math.pi / 180.0);
  final dLon = (b.longitude - a.longitude) * 111320.0 * cosLat;
  return math.sqrt(dLat * dLat + dLon * dLon);
}
