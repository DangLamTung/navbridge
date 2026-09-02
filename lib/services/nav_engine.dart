/// Turn-by-turn engine: snaps GPS fixes to the OSRM route polyline and emits
/// the data needed for the E-ink nav frame (distance, icon, ETA, text).
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/osrm.dart';

/// Everything needed to build a nav frame for the clock.
class NavProgress {
  final int meter; // distance to the next maneuver
  final int iconCode;
  final int nextIconCode; // maneuver right after the current one (0 = none)
  final String nextText; // road name for the next maneuver

  /// Distance (meters) to the maneuver AFTER the upcoming one — the "next of
  /// next". 0 when there is no second maneuver. Fed to the ESP32 nav2 packet.
  final int nextMeter;

  /// Road name for the maneuver AFTER the upcoming one (the "next of next";
  /// '' when there is none) — shown in simple nav mode since there's no map
  /// to see what's coming.
  final String nextNextText;
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

  /// Distance REMAINING to the FINAL destination (not the next maneuver),
  /// metres. The ETA card shows this — "6.6 km • 12:15" — while [meter]
  /// stays the distance to the next turn.
  final double remainingMeters;

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
    this.nextNextText = '',
    this.nextMeter = 0,
    this.stopIndex = 0,
    this.totalStops = 0,
    this.stopName = '',
    this.progress = 0,
    this.remainingMeters = 0,
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

  /// Adaptive ETA state. The routing engine's `duration` is a static profile
  /// estimate; once the driver has been moving for a few fixes we scale the
  /// remaining time by how much faster/slower they actually travel than the
  /// route's implied mean speed, so a traffic jam or a fast pace is reflected
  /// live. A re-route creates a fresh engine → these reset.
  double _etaEmaMps =
      0; // exponential moving average of GPS speed (moving only)
  int _etaMovingFixes = 0; // moving fixes seen (warm-up before adapting)
  double _etaFactor = 1.0; // 1.0 until enough moving fixes engage adaptation

  /// Current adaptive-ETA factor (profile speed ÷ actual speed, clamped to
  /// 0.5–3.0). 1.0 = not yet engaged (still the pure profile ETA).
  double get etaFactor => _etaFactor;

  /// Legal maximum cruise speed (m/s) for this vehicle — the ETA's assumed
  /// pace is CAPPED here (Vietnamese road law), so a short 100 km/h burst can
  /// never make the arrival time unrealistically optimistic.
  final double maxSpeedMps;

  TurnByTurnEngine(
    this.route, {
    List<String>? stopNames,
    this.maxSpeedMps = 33.3, // ~120 km/h (car) — overridden by the caller
  }) : stopNames = stopNames ?? const [],
       _stopCum = List.of(route.stopCumulative) {
    // Fast approximate metres per segment — this loop runs the WHOLE route
    // synchronously on the main thread right after routing; haversine over
    // tens of thousands of vertices is what froze long-distance routes.
    var c = 0.0;
    _cum.add(0);
    for (var i = 1; i < route.geometry.length; i++) {
      c += fastDistanceMeters(route.geometry[i - 1], route.geometry[i]);
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
    // Shortest-path difference, then low-pass (smoothly transition without abrupt 180 flips).
    var d = (raw - _smBearing + 540) % 360 - 180;
    if (d.abs() < 0.5) {
      d = 0;
    } else {
      d = (d * 0.35).clamp(-20.0, 20.0);
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
  /// Used by the simulated-drive mode and the route-ahead bearing.
  ///
  /// [_cum] is monotonically increasing, so a binary search (O(log n)) finds
  /// the segment instead of the old linear scan from index 1 on every call —
  /// which was O(route length) per GPS fix (routeBearing → positionAtDistance)
  /// and scaled with route size, adding to the long-route freeze.
  LatLng positionAtDistance(double d) {
    final pts = route.geometry;
    if (pts.isEmpty) return const LatLng(0, 0);
    if (d <= 0) return pts.first;
    if (d >= _cum.last) return pts.last;
    var lo = 1;
    var hi = _cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] >= d) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final i = lo;
    final seg = _cum[i] - _cum[i - 1];
    final t = seg == 0 ? 0.0 : (d - _cum[i - 1]) / seg;
    final a = pts[i - 1];
    final b = pts[i];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Feed a GPS fix; returns the current nav progress.
  NavProgress update(LatLng pos, {double speedMps = 0}) {
    _curIdx = _nearestIndex(pos);
    final cum = _cum[_curIdx];

    // Advance to the first step whose maneuver is still ahead of us. The
    // advance margin scales with speed: at 60 km/h a fixed 3 m lead is only
    // ~180 ms of travel, so a GPS fix that lands a second late could mark a
    // maneuver passed before the UI/voice delivered the final instruction.
    // Give ~0.8 s of travel (min 3 m) based on the car's real pace.
    final advanceMargin = math.max(3.0, speedMps * 0.8);
    while (_nextStep < route.steps.length - 1 &&
        _stepCum[_nextStep] < cum + advanceMargin) {
      _nextStep++;
    }
    // The upcoming maneuver is the step AFTER the one we're on: step
    // `_nextStep` is the road we're already travelling (its maneuver — e.g.
    // the last left turn — is behind us), and its END (`_stepCum[_nextStep]`)
    // is where the NEXT maneuver lives. Announcing `steps[_nextStep]` made
    // the spoken direction lag one turn behind (a "turn right" heard right
    // after you'd actually made it, or a left/right that looked swapped).
    final cur = route.steps[_nextStep]; // current road (for the name)
    final upIdx = (_nextStep + 1).clamp(0, route.steps.length - 1);
    final upcoming = route.steps[upIdx]; // the maneuver we're approaching
    final nextIdx = upIdx + 1;
    final next = nextIdx < route.steps.length ? route.steps[nextIdx] : null;

    final meter = (_stepCum[_nextStep] - cum).clamp(0, route.distance).round();
    var icon = iconForManeuver(upcoming.type, upcoming.modifier);
    // Don't announce "you have arrived" from the start of the last long road
    // — keep "go straight" until the destination is actually close.
    if (upcoming.type == 'arrive' && meter > 80) icon = iconStraight;

    // ETA from the remaining duration (proportional to remaining distance),
    // then ADAPTED to the driver's real pace: the routing engine's duration
    // assumes a static profile speed, so once we have a few moving fixes we
    // scale the remaining time by profileSpeed / actualSpeed (clamped) —
    // slower driving (traffic/wind) lengthens it, a fast pace shortens it.
    // The speed is CAPPED at the vehicle's legal max ([maxSpeedMps]) so a
    // short 100 km/h burst on an 80 km/h road can never halve the ETA (the
    // driver will be back at legal pace shortly); the factor floor is 0.6
    // (was 0.5) so the ETA can't claim more than ~1.6× the legal pace.
    final remainBase =
        (route.duration * ((route.distance - cum) / route.distance));
    if (speedMps > 1.0) {
      _etaMovingFixes++;
      _etaEmaMps = _etaEmaMps == 0
          ? speedMps
          : 0.1 * speedMps + 0.9 * _etaEmaMps;
    }
    var remainSec = remainBase.round();
    final profileMps = route.duration > 0
        ? route.distance / route.duration
        : 0.0;
    _etaFactor = 1.0;
    if (_etaMovingFixes >= 8 && _etaEmaMps > 1.5 && profileMps > 0) {
      // Cap the EMA at the vehicle's legal max before comparing to the
      // profile pace, so a burst can't push the factor below the law.
      final legalCapped = math.min(_etaEmaMps, maxSpeedMps);
      final factor = (profileMps / legalCapped).clamp(0.6, 3.0);
      _etaFactor = factor;
      remainSec = (remainBase * factor).round();
    }
    final eta = DateTime.now().add(Duration(seconds: remainSec));

    final text = cur.name.isNotEmpty ? cur.name : 'Tiến lên';

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
      // The road you turn INTO for the upcoming maneuver (used by the voice
      // announcement "turn left onto X" and the "then" chip).
      nextText: upcoming.name,
      nextNextText: next == null ? '' : next.name,
      nextMeter: next == null
          ? 0
          : (_stepCum[nextIdx] - cum).clamp(0, route.distance).round(),
      etaHour: eta.hour,
      etaMinute: eta.minute,
      text: text,
      maneuver: upcoming.maneuver,
      speedMps: speedMps,
      stopIndex: stopIndex,
      totalStops: _stopCum.length,
      stopName: stopName,
      progress: route.distance <= 0
          ? 0
          : (cum / route.distance).clamp(0.0, 1.0),
      // Distance to the FINAL point (not the next maneuver).
      remainingMeters: route.distance <= 0
          ? 0
          : (route.distance - cum).clamp(0.0, route.distance),
    );
  }

  /// Nearest polyline index to `pos`, searching around the last snap first.
  ///
  /// IMPORTANT: the ±[win] window is searched first and the O(n) full scan is
  /// ONLY a fallback when the window finds nothing close (car genuinely far
  /// from this part of the route — fresh route / big detour). The old code
  /// always fell through to the full scan on every GPS fix, which made the
  /// per-fix cost O(route length) — a long route (tens of thousands of
  /// vertices) kept the low-end phone's main thread busy for ~20 ms+ every
  /// fix (2 full scans per fix: offRouteDistance + update), the sustained
  /// CPU that shows up as the "not responding" ANR on long routes.
  int _nearestIndex(LatLng pos) {
    final n = route.geometry.length;
    if (n <= 1) return 0;

    var best = _curIdx.clamp(0, n - 1);
    var bestD = distanceMeters(pos, route.geometry[best]);
    const win = 120;
    final lo = (best - win).clamp(0, n - 1);
    final hi = (best + win).clamp(0, n - 1);
    for (var i = lo; i <= hi; i++) {
      final d = distanceMeters(pos, route.geometry[i]);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    // Car is on/near the route → the window is enough. Only scan everything
    // when the car is far off this stretch (fresh route, big reroute).
    if (bestD > 25) {
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
