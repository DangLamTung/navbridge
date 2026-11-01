/// Live-traffic reading for a planned route.
///
/// Source: Google Routes API `computeRoutes` with
/// `extraComputations: ["TRAFFIC_ON_POLYLINE"]`, which returns
/// `travelAdvisory.speedReadingIntervals` — `NORMAL` / `SLOW` / `TRAFFIC_JAM`
/// runs of polyline indices — plus `duration` (with traffic) and
/// `staticDuration` (free-flow).
///
/// DESIGN NOTES
///
///  * The indices refer to the polyline of the route that produced them. When
///    the route came from Google itself (the motorbike engine) the geometry is
///    that same polyline, so the indices apply directly. For another provider
///    (OSRM / Vietmap) the runs are re-anchored with [remapTo].
///  * Nothing here paints anything: `TrafficSpan`s are index ranges so both
///    renderers (flutter_map and MapLibre) can slice their own geometry.
///  * COST: this rides on the Routes API call the route already makes. For the
///    motorbike engine the request is Enterprise-tier either way
///    (`TWO_WHEELER`), so the intervals add no billable event.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// How fast traffic moves on a stretch, in Google's own three bands.
enum TrafficLevel { normal, slow, jam }

/// Speed ratio (implied live speed ÷ free-flow speed) below which a Google
/// `SLOW` run is drawn as a JAM (red) instead of slow (yellow) — see
/// [RouteTraffic.grade].
const double kCrawlRatio = 0.6;

/// A run only turns red when the pattern actually costs something: at least
/// this many seconds lost, and at least [kCrawlMinFreeS] seconds of free-flow
/// driving to lose them over. Without the floor a 3-vertex stub that happens to
/// be one minute slow turned a whole street red.
const double kCrawlMinLostS = 60.0;
const double kCrawlMinFreeS = 30.0;

/// One run of the polyline at a single [TrafficLevel].
///
/// [end] is EXCLUSIVE (Google's own convention: the next interval starts where
/// this one ends), so a span covers indices `start..end-1`.
class TrafficSpan {
  const TrafficSpan({
    required this.start,
    required this.end,
    required this.level,
  });

  final int start;
  final int end;
  final TrafficLevel level;

  int get length => end - start;

  @override
  String toString() => 'TrafficSpan($start..$end $level)';
}

class RouteTraffic {
  const RouteTraffic({
    required this.live,
    required this.freeFlow,
    required this.spans,
    this.measuredAt,
    this.forTime,
    this.estimated = false,
  });

  /// Travel time WITH traffic (Google `duration`).
  final Duration live;

  /// Travel time at free-flow speed (Google `staticDuration`).
  final Duration freeFlow;

  /// Ordered runs over the route geometry.
  final List<TrafficSpan> spans;

  /// WHEN the reading describes: the moment the API answered (live traffic) or
  /// the hour the history model was asked about. Shown to the driver as
  /// "lúc 12:21" so a stale reading is never mistaken for now.
  final DateTime? measuredAt;

  /// The departure time the estimate is FOR. Live reads use t+2min (Google
  /// rejects "now"); history reads use the planned departure. Null = unknown.
  final DateTime? forTime;

  /// True when the numbers come from the device's own recorded drives
  /// ([TrafficHistory]) instead of a live provider — the chip says
  /// "dự đoán" so the driver knows it is a pattern, not this minute's jam.
  final bool estimated;

  /// "lúc 12:21" / "dự đoán 18:00" — the label for the traffic chip.
  String get timeLabel {
    final t = forTime ?? measuredAt;
    if (t == null) return '';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return estimated ? 'dự đoán $hh:$mm' : 'lúc $hh:$mm';
  }

  /// Seconds slower than free flow. Google sometimes predicts FASTER than
  /// free-flow (two-wheelers filtering through a jam), so this can be
  /// negative — [delayed] is what the UI asks.
  int get delaySeconds => live.inSeconds - freeFlow.inSeconds;

  /// Worth telling the driver about: at least a minute lost.
  bool get delayed => delaySeconds >= 60;

  /// "+18 phút" for the ETA line, '' when there is nothing to report.
  String get delayLabel =>
      delayed ? '+${(delaySeconds / 60).round()} phút' : '';

  /// Runs that are not free-flow — the ones worth colouring.
  List<TrafficSpan> get jams =>
      spans.where((s) => s.level != TrafficLevel.normal).toList();

  bool get hasJams => jams.isNotEmpty;

  /// Total length in metres of the jammed runs, given a route of [totalMeters]
  /// with [points] vertices — used for "kẹt xe 2,3 km" chip text.
  double jamMeters(int points, double totalMeters) {
    if (points < 2 || totalMeters <= 0) return 0;
    var m = 0.0;
    final per = totalMeters / (points - 1);
    for (final s in jams) {
      m += s.length * per;
    }
    return m;
  }

  /// Re-anchor these spans onto ANOTHER geometry (a route planned by a
  /// different provider).
  ///
  /// The two routes are the same origin → destination but rarely the same
  /// vertex list, so each jam run is matched by its MIDPOINT: the nearest point
  /// of [to] to the middle of the run becomes the centre of the new run, whose
  /// length is preserved in metres. Approximate by construction — a jam run
  /// that the other provider did not take cannot be placed exactly — but it
  /// keeps a jam visible on the right stretch of road instead of dropping it.
  ///
  /// [from] is the geometry the spans index; [fromMeters]/[toMeters] are the
  /// two route lengths.
  static List<TrafficSpan> remap(
    List<TrafficSpan> spans,
    List<LatLng> from,
    List<LatLng> to, {
    double fromMeters = 0,
    double toMeters = 0,
  }) {
    if (spans.isEmpty || from.length < 2 || to.length < 2) return const [];
    final fromPer = fromMeters > 0 ? fromMeters / (from.length - 1) : 0.0;
    final toPer = toMeters > 0 ? toMeters / (to.length - 1) : 0.0;
    final out = <TrafficSpan>[];
    for (final s in spans) {
      final mid = (s.start + s.end) ~/ 2;
      final anchor = from[mid.clamp(0, from.length - 1)];
      var best = 0;
      var bestD = double.infinity;
      for (var i = 0; i < to.length; i++) {
        final d = _sq(anchor, to[i]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      final spanMeters = fromPer > 0 && toPer > 0
          ? s.length * fromPer
          : (toMeters > 0 ? s.length * toPer : 0.0);
      final half = toPer > 0 && spanMeters > 0
          ? (spanMeters / 2 / toPer).round()
          : (s.length / 2).round().clamp(1, 100000);
      final a = (best - half).clamp(0, to.length - 1);
      final b = (best + half).clamp(a + 1, to.length);
      out.add(TrafficSpan(start: a, end: b, level: s.level));
    }
    return out;
  }

  static double _sq(LatLng a, LatLng b) {
    final dy = a.latitude - b.latitude;
    final dx = a.longitude - b.longitude;
    return dx * dx + dy * dy;
  }

  /// Parse `travelAdvisory.speedReadingIntervals` from one Google route.
  ///
  /// [geometry] is the polyline the indices point into; runs are clamped to it
  /// so a malformed index can never make a renderer throw.
  static RouteTraffic? fromGoogle(
    Map<String, dynamic> route,
    List<LatLng> geometry, {
    required int Function(String) seconds,
    DateTime? measuredAt,
    DateTime? forTime,
  }) {
    final adv = route['travelAdvisory'];
    final raw = adv is Map ? adv['speedReadingIntervals'] : null;
    final spans = <TrafficSpan>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final a = (e['startPolylinePointIndex'] as num?)?.toInt();
        final b = (e['endPolylinePointIndex'] as num?)?.toInt();
        if (a == null || b == null) continue;
        final lvl = switch ((e['speed'] as String?) ?? 'NORMAL') {
          'TRAFFIC_JAM' => TrafficLevel.jam,
          'SLOW' => TrafficLevel.slow,
          _ => TrafficLevel.normal,
        };
        final start = a.clamp(0, geometry.length < 2 ? 0 : geometry.length - 1);
        final end = b.clamp(start, geometry.length);
        if (end > start) {
          spans.add(TrafficSpan(start: start, end: end, level: lvl));
        }
      }
    }
    final live = Duration(
      seconds: seconds((route['duration'] as String?) ?? ''),
    );
    final free = Duration(
      seconds: seconds((route['staticDuration'] as String?) ?? ''),
    );
    if (live.inSeconds <= 0 && free.inSeconds <= 0) return null;
    final liveD = live.inSeconds > 0 ? live : free;
    final freeD = free.inSeconds > 0 ? free : live;
    return RouteTraffic(
      live: liveD,
      freeFlow: freeD,
      spans: grade(
        spans,
        geometry,
        delaySeconds: liveD.inSeconds - freeD.inSeconds,
        freeFlowSeconds: freeD.inSeconds,
      ),
      measuredAt: measuredAt,
      forTime: forTime,
    );
  }

  /// Split Google's single "SLOW" band into the two shades drivers expect.
  ///
  /// Google answers with three bands (`NORMAL` / `SLOW` / `TRAFFIC_JAM`), but
  /// in Việt Nam two-wheeler coverage almost never emits `TRAFFIC_JAM` —
  /// measured 2026-10-31 at midday AND for a predicted 18:00 rush hour on the
  /// 71 km HCMC → Long An corridor: 3 intervals, one `SLOW`, no jam. A map with
  /// only one warning colour cannot tell "slow" from "crawling", so the band is
  /// kept and the SHADE is decided by a measured number:
  ///
  ///   * the route's own lost time (`live - freeFlow`) is apportioned to the
  ///     non-normal runs by length — a run that carries more of the delay is
  ///     moving slower;
  ///   * a `SLOW` run whose implied speed falls under [kCrawlRatio] of
  ///     free-flow is drawn as a JAM (red), the rest stay slow (yellow).
  ///
  /// With no delay in the response (traffic as fast as free-flow) the band is
  /// left exactly as Google said.
  static List<TrafficSpan> grade(
    List<TrafficSpan> spans,
    List<LatLng> geometry, {
    required int delaySeconds,
    required int freeFlowSeconds,
  }) {
    final out = [
      for (final s in spans)
        TrafficSpan(
          start: s.start,
          end: s.end,
          level: s.level == TrafficLevel.jam ? TrafficLevel.jam : s.level,
        ),
    ];
    if (delaySeconds <= 0 || geometry.length < 2) return out;
    final congested = [
      for (var i = 0; i < out.length; i++)
        if (out[i].level != TrafficLevel.normal) i,
    ];
    if (congested.isEmpty) return out;
    var congestedM = 0.0;
    final metres = <int, double>{};
    for (final i in congested) {
      final m = _spanMetres(out[i], geometry);
      metres[i] = m;
      congestedM += m;
    }
    if (congestedM <= 0) return out;
    var totalM = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      totalM += _m(geometry[i], geometry[i + 1]);
    }
    for (final i in congested) {
      if (out[i].level != TrafficLevel.slow) continue;
      final share = metres[i]! / congestedM;
      final lost = delaySeconds * share;
      // Free-flow time of this run, as a share of the route's free-flow time.
      final freeShare = totalM > 0 ? metres[i]! / totalM : share;
      final freeS = freeShare * freeFlowSeconds;
      final ratio = freeS + lost > 0 ? freeS / (freeS + lost) : 1.0;
      if (ratio < kCrawlRatio &&
          lost >= kCrawlMinLostS &&
          freeS >= kCrawlMinFreeS) {
        out[i] = TrafficSpan(
          start: out[i].start,
          end: out[i].end,
          level: TrafficLevel.jam,
        );
      }
    }
    return out;
  }

  static double _spanMetres(TrafficSpan s, List<LatLng> geo) {
    var m = 0.0;
    for (var i = s.start; i < s.end && i + 1 < geo.length; i++) {
      m += _m(geo[i], geo[i + 1]);
    }
    return m;
  }

  static double _m(LatLng a, LatLng b) {
    final dy = (b.latitude - a.latitude) * 111320.0;
    final dx =
        (b.longitude - a.longitude) *
        111320.0 *
        math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }
}
