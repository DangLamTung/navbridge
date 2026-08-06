/// Turn-by-turn engine: snaps GPS fixes to the OSRM route polyline and emits
/// the data needed for the E-ink nav frame (distance, icon, ETA, text).
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'nav_protocol.dart';
import 'osrm.dart';

/// Everything needed to build a nav frame for the clock.
class NavProgress {
  final int meter; // distance to the next maneuver
  final int iconCode;
  final int nextIconCode; // maneuver right after the current one (0 = none)
  final String nextText; // road name for the next maneuver
  final int etaHour;
  final int etaMinute;
  final String text; // road name / instruction

  /// Coordinates of the upcoming maneuver — used to tell apart consecutive
  /// turns that share the same icon + road name (complex multi-turn areas).
  final LatLng? maneuver;

  final double speedMps;
  final int stopIndex; // 0-based stop we're approaching (0 when none)
  final int totalStops; // number of stops incl. the final destination
  final String stopName; // name of the approaching stop ('' when none)

  /// Fraction of the route already travelled (0..1) — drives the
  /// Google-style trip progress bar at the top of the nav screen.
  final double progress;

  NavProgress({
    required this.meter,
    required this.iconCode,
    required this.etaHour,
    required this.etaMinute,
    required this.text,
    this.maneuver,
    required this.speedMps,
    this.nextIconCode = 0,
    this.nextText = '',
    this.stopIndex = 0,
    this.totalStops = 0,
    this.stopName = '',
    this.progress = 0,
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
  int _curSeg =
      0; // segment index the car projects onto (for route "consuming")

  /// Last position projected onto the route — used as the origin of the
  /// route-ahead bearing ([routeBearing]).
  LatLng? _lastSnapped;

  /// Smoothed route-ahead bearing (deg, 0=N) — the value that drives the
  /// arrow and the heading-up camera. Low-pass filtered so GPS jitter and
  /// nearest-segment flips can never make it (or the arrow) spin/flicker.
  double _smBearing = 0;
  bool _hasSmBearing = false;

  /// Meters ahead of the car used for the route-ahead bearing (MapLibre /
  /// Vietmap look-ahead style): far enough to be stable against GPS jitter,
  /// close enough that it still follows the road through a curve.
  static const double _lookAheadMeters = 25.0;

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

  double get currentCumulative => _cum[_curIdx];

  /// Distance from [pos] to the nearest route point (off-route detection).
  double offRouteDistance(LatLng pos) =>
      distanceMeters(pos, route.geometry[_nearestIndex(pos)]);

  /// Project [pos] onto the route polyline — the closest point on the nearest
  /// segment (not just the nearest vertex). This is the "car on the road"
  /// position: feeding it (instead of the raw GPS fix) to the engine/map keeps
  /// the puck glued to the route and the route-bearing camera steady, so GPS
  /// noise never pulls the car off the road or makes the arrow flicker.
  ///
  /// Searches a window around the last snapped index first (the car moves
  /// continuously along the route) and falls back to a full scan when the
  /// window finds nothing close (e.g. a brand-new route after a re-route).
  LatLng snapToRoute(LatLng pos) {
    final pts = route.geometry;
    if (pts.length < 2) {
      _lastSnapped = pos;
      return pos;
    }
    const win = 80;
    var bestSeg = -1;
    var bestScore = double.infinity; // distance + continuity penalty (meters)
    var bestRaw = double.infinity; // pure perpendicular distance (meters)
    final start = _curIdx.clamp(0, pts.length - 2);
    final lo = (start - win).clamp(0, pts.length - 2);
    final hi = (start + win).clamp(0, pts.length - 2);
    for (var i = lo; i <= hi; i++) {
      final (_, d2) = _closestOnSegment(pos, pts[i], pts[i + 1]);
      final d = math.sqrt(d2);
      // Continuity (hysteresis): a segment far from the one we're already on
      // must be CLEARLY closer to win — otherwise GPS noise near a fork or a
      // vertex could jump the projection to a wrong parallel road / ahead
      // segment and the car would lurch forward (or snap back) on the route.
      final jump = (i - _curSeg).abs() < 3 ? 0.0 : 12.0;
      final score = d + jump;
      if (score < bestScore) {
        bestScore = score;
        bestRaw = d;
        bestSeg = i;
      }
    }
    // Full-scan fallback: the window found nothing close (a re-route just set
    // a fresh route, or the car is well off the old segment). Distance only —
    // continuity is meaningless when we're not on the route yet.
    if (bestSeg < 0 || bestRaw > 25) {
      for (var i = 0; i < pts.length - 1; i++) {
        final (_, d2) = _closestOnSegment(pos, pts[i], pts[i + 1]);
        final d = math.sqrt(d2);
        if (d < bestRaw) {
          bestRaw = d;
          bestSeg = i;
        }
      }
    }
    if (bestSeg < 0) {
      _lastSnapped = pos;
      return pos;
    }
    // Monotonic: the car only ever drives forward, so the consumed start must
    // never move backward (GPS noise could make the nearest segment flip to an
    // earlier one → the drawn route would briefly "grow back").
    _curSeg = math.max(_curSeg, bestSeg);
    final (proj, _) = _closestOnSegment(pos, pts[bestSeg], pts[bestSeg + 1]);
    _lastSnapped = proj;
    return proj;
  }

  /// Index of the route segment the car currently projects onto — the car is
  /// between vertex [snappedSegmentIndex] and [snappedSegmentIndex]+1. The
  /// driven part of the route (vertices before this) can be dropped from the
  /// drawn polyline.
  int get snappedSegmentIndex => _curSeg;

  /// Smoothed bearing (0=N, clockwise) of the route just ahead of the car —
  /// the value that drives the arrow and the heading-up camera. This is the
  /// MapLibre / Vietmap "snap location bearing" approach: the direction from
  /// the car's snapped position toward a point [_lookAheadMeters] ahead on
  /// the route, low-pass filtered.
  ///
  /// Never the raw nearest-segment bearing (which flips between adjacent
  /// segments at a vertex and under GPS jitter — that flip is what made the
  /// arrow/camera snap back and forth / flicker) and never the phone compass.
  ///
  /// Filtering: micro-jitter (<0.5°) is zeroed, medium wobble is attenuated
  /// 70%, and real changes (approaching a turn) pass through so the camera
  /// animation still rotates the map for an actual corner.
  double routeBearing() {
    final pts = route.geometry;
    if (pts.length < 2) return _hasSmBearing ? _smBearing : 0;
    final proj = _lastSnapped;
    if (proj == null) return _hasSmBearing ? _smBearing : 0;
    // Cumulative distance at the SNAPPED point (not the nearest vertex — that
    // can be behind/ahead of the car and would make the look-ahead point the
    // wrong way mid-segment).
    final seg = _curSeg.clamp(0, pts.length - 2);
    final snapCum = _cum[seg] + distanceMeters(pts[seg], proj);
    final target = (snapCum + _lookAheadMeters).clamp(snapCum, _cum.last);
    if (target <= snapCum) {
      // At the very end of the route — hold the last bearing.
      return _hasSmBearing ? _smBearing : _bearingBetween(proj, pts.last);
    }
    final to = positionAtDistance(target);
    final raw = _bearingBetween(proj, to);
    if (!_hasSmBearing) {
      _smBearing = raw;
      _hasSmBearing = true;
      return raw;
    }
    // Shortest-path difference, then low-pass.
    var d = (raw - _smBearing + 540) % 360 - 180;
    if (d.abs() < 0.5) {
      d = 0;
    } else if (d.abs() < 20) {
      d *= 0.3;
    }
    _smBearing = (_smBearing + d + 360) % 360;
    return _smBearing;
  }

  /// Offset [pos] laterally — perpendicular to the route at [pos] — by
  /// [meters] (positive = right of the travel direction). Used to inject
  /// realistic GPS error that is mostly CROSS-TRACK: that is the component
  /// the road-snapping ([snapToRoute]) must correct (along-track error just
  /// slides the car forward/back on the road and adds no value).
  LatLng lateralOffset(LatLng pos, double meters) {
    final pts = route.geometry;
    if (pts.length < 2) return pos;
    // Nearest segment to [pos] (search around the car's current segment).
    var seg = _curSeg.clamp(0, pts.length - 2);
    var bestD = double.infinity;
    const win = 20;
    final lo = (seg - win).clamp(0, pts.length - 2);
    final hi = (seg + win).clamp(0, pts.length - 2);
    for (var i = lo; i <= hi; i++) {
      final (_, d) = _closestOnSegment(pos, pts[i], pts[i + 1]);
      if (d < bestD) {
        bestD = d;
        seg = i;
      }
    }
    final a = pts[seg];
    final b = pts[seg + 1];
    // Perpendicular to the travel direction (right side = bearing + 90°).
    final rad = (_bearingBetween(a, b) + 90) * math.pi / 180;
    final dLat = meters * math.cos(rad) / 111320.0;
    final dLng =
        meters *
        math.sin(rad) /
        (111320.0 * math.cos(pos.latitude * math.pi / 180));
    return LatLng(pos.latitude + dLat, pos.longitude + dLng);
  }

  /// Bearing (0=N, clockwise) of the straight line from [a] to [b].
  double _bearingBetween(LatLng a, LatLng b) {
    final y =
        math.sin((b.longitude - a.longitude) * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180);
    final x =
        math.cos(a.latitude * math.pi / 180) *
            math.sin(b.latitude * math.pi / 180) -
        math.sin(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.cos((b.longitude - a.longitude) * math.pi / 180);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Closest point on segment [a]-[b] to [p], plus its squared distance
  /// (equirectangular meters about [p]) — used by [snapToRoute].
  (LatLng, double) _closestOnSegment(LatLng p, LatLng a, LatLng b) {
    const mPerLat = 111320.0;
    final mPerLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    // Local meters with p at the origin.
    final ax = (a.longitude - p.longitude) * mPerLng;
    final ay = (a.latitude - p.latitude) * mPerLat;
    final bx = (b.longitude - p.longitude) * mPerLng;
    final by = (b.latitude - p.latitude) * mPerLat;
    final abx = bx - ax;
    final aby = by - ay;
    final len2 = abx * abx + aby * aby;
    // t = -(a·(b−a))/|b−a|²  clamped to [0,1] → closest point on the segment.
    var t = len2 == 0 ? 0.0 : -(ax * abx + ay * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cLat = a.latitude + t * (b.latitude - a.latitude);
    final cLng = a.longitude + t * (b.longitude - a.longitude);
    final cx = ax + t * abx;
    final cy = ay + t * aby;
    return (LatLng(cLat, cLng), cx * cx + cy * cy);
  }

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
    final nextIdx = _nextStep + 1;
    final next = nextIdx < route.steps.length ? route.steps[nextIdx] : null;

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
    final stopIndex = _stopCum.isEmpty
        ? 0
        : passed.clamp(0, _stopCum.length - 1);
    final stopName = stopIndex < stopNames.length ? stopNames[stopIndex] : '';

    return NavProgress(
      meter: meter,
      iconCode: icon,
      nextIconCode: next == null
          ? 0
          : iconForManeuver(next.type, next.modifier),
      nextText: next?.name ?? '',
      etaHour: eta.hour,
      etaMinute: eta.minute,
      text: text,
      maneuver: step.maneuver,
      speedMps: speedMps,
      stopIndex: stopIndex,
      totalStops: _stopCum.length,
      stopName: stopName,
      progress: route.distance <= 0
          ? 0
          : (cum / route.distance).clamp(0.0, 1.0),
    );
  }

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
