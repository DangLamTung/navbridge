/// Turn-by-turn engine: snaps GPS fixes to the OSRM route polyline and emits
/// the data needed for the E-ink nav frame (distance, icon, ETA, text).
library;

import 'package:latlong2/latlong.dart';

import 'nav_protocol.dart';
import 'osrm.dart';

/// Everything needed to build a nav frame for the clock.
class NavProgress {
  final int meter; // distance to the next maneuver
  final int iconCode;
  final int etaHour;
  final int etaMinute;
  final String text; // road name / instruction
  final double speedMps;
  final int stopIndex; // 0-based stop we're approaching (0 when none)
  final int totalStops; // number of stops incl. the final destination
  final String stopName; // name of the approaching stop ('' when none)

  NavProgress({
    required this.meter,
    required this.iconCode,
    required this.etaHour,
    required this.etaMinute,
    required this.text,
    required this.speedMps,
    this.stopIndex = 0,
    this.totalStops = 0,
    this.stopName = '',
  });
}

class TurnByTurnEngine {
  final OsrmRoute route;
  final List<String> stopNames; // names of the stops (intermediate + final)

  final List<double> _cum = []; // cumulative meters along the full polyline
  final List<double> _stepCum = []; // cumulative meters at each step maneuver
  final List<double> _stopCum; // cumulative meters at each stop
  int _curIdx = 0; // last snapped polyline index (optimization window)
  int _nextStep = 0; // index of the upcoming maneuver step

  TurnByTurnEngine(this.route, {List<String>? stopNames})
      : stopNames = stopNames ?? const [],
        _stopCum = List.of(route.stopCumulative) {
    var c = 0.0;
    _cum.add(0);
    for (var i = 1; i < route.geometry.length; i++) {
      c += distanceMeters(route.geometry[i - 1], route.geometry[i]);
      _cum.add(c);
    }
    var sc = 0.0;
    for (final s in route.steps) {
      sc += s.distance;
      _stepCum.add(sc > c ? c : sc);
    }
  }

  double get totalDistance => route.distance;

  /// Cumulative distance along the route at the last snapped position.
  double get currentCumulative => _cum[_curIdx];

  /// Distance from [pos] to the nearest route point (off-route detection).
  double offRouteDistance(LatLng pos) =>
      distanceMeters(pos, route.geometry[_nearestIndex(pos)]);

  /// Interpolate a point at [d] meters along the route polyline.
  /// Used by the simulated-drive mode.
  LatLng positionAtDistance(double d) {
    final pts = route.geometry;
    if (pts.isEmpty) return const LatLng(0, 0);
    if (d <= 0) return pts.first;
    if (d >= _cum.last) return pts.last;
    for (var i = 1; i < _cum.length; i++) {
      if (_cum[i] >= d) {
        final seg = _cum[i] - _cum[i - 1];
        final t = seg == 0 ? 0.0 : (d - _cum[i - 1]) / seg;
        final a = pts[i - 1];
        final b = pts[i];
        return LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
      }
    }
    return pts.last;
  }

  /// Feed a GPS fix; returns the current nav progress.
  NavProgress update(LatLng pos, {double speedMps = 0}) {
    _curIdx = _nearestIndex(pos);
    final cum = _cum[_curIdx];

    // Advance to the first step whose maneuver is still ahead of us.
    while (_nextStep < route.steps.length - 1 &&
        _stepCum[_nextStep] < cum + 3) {
      _nextStep++;
    }
    final step = route.steps[_nextStep];

    final meter = (_stepCum[_nextStep] - cum).clamp(0, route.distance).round();
    final icon = iconForManeuver(step.type, step.modifier);

    // ETA from the remaining duration (proportional to remaining distance).
    final remainSec =
        (route.duration * ((route.distance - cum) / route.distance)).round();
    final eta = DateTime.now().add(Duration(seconds: remainSec));

    final text = step.name.isNotEmpty ? step.name : 'Tiến lên';

    // Which stop are we heading to?
    var passed = 0;
    while (passed < _stopCum.length && _stopCum[passed] < cum) {
      passed++;
    }
    final stopIndex =
        _stopCum.isEmpty ? 0 : passed.clamp(0, _stopCum.length - 1);
    final stopName = stopIndex < stopNames.length ? stopNames[stopIndex] : '';

    return NavProgress(
      meter: meter,
      iconCode: icon,
      etaHour: eta.hour,
      etaMinute: eta.minute,
      text: text,
      speedMps: speedMps,
      stopIndex: stopIndex,
      totalStops: _stopCum.length,
      stopName: stopName,
    );
  }

  /// Distance along the route from a snapped polyline index to the end.
  double remainingFromIndex(int idx) =>
      route.distance - _cum[idx].clamp(0, route.distance);

  /// Nearest polyline index to `pos`, searching around the last snap first.
  int _nearestIndex(LatLng pos) {
    final n = route.geometry.length;
    if (n <= 1) return 0;

    var best = _curIdx.clamp(0, n - 1);
    var bestD = distanceMeters(pos, route.geometry[best]);
    // Search a window around the previous position, then fall back to full.
    const win = 60;
    final lo = (best - win).clamp(0, n - 1);
    final hi = (best + win).clamp(0, n - 1);
    for (var i = lo; i <= hi; i++) {
      final d = distanceMeters(pos, route.geometry[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (lo > 0 || hi < n - 1) {
      for (var i = 0; i < n; i++) {
        if (i >= lo && i <= hi) continue;
        final d = distanceMeters(pos, route.geometry[i]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    return best;
  }
}
