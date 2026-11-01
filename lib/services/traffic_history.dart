/// OFFLINE traffic — predicted from the device's OWN recorded drives.
///
/// Why this exists: the live providers (Google Routes, Vietmap congestion) all
/// need a network and a key, and the app is offline-first — on a rural stretch,
/// in a tunnel, or with the key exhausted, the map used to say nothing at all
/// about traffic. But this app already records every drive it makes (`saveTrip`
/// writes speed, position and posted limit per fix), and a road's congestion is
/// highly periodic: Cộng Hòa at 17:30 on a Friday is jammed every week.
///
/// So the device keeps a small aggregate of "how fast did traffic actually move
/// here, at this hour, on this kind of day":
///
///   * key = grid cell (≈200 m) + hour bucket + weekday/weekend;
///   * value = sample count and the mean speed ratio (achieved ÷ posted limit);
///   * a cell needs [kMinSamples] samples before it may colour anything, so one
///     red light does not turn a street red forever.
///
/// It is deliberately a PATTERN model, not a live feed: [RouteTraffic.estimated]
/// is set so the UI says "dự đoán" rather than pretending it is this minute.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'route_traffic.dart';
import 'trip_logger.dart' show TripLogger;

/// Grid cell size in degrees. 0.002° ≈ 222 m — one block, so a jam on one side
/// of a junction does not bleed into the free-flowing cross street.
const double kHistoryCellDeg = 0.002;

/// Samples a cell+hour needs before it may colour a route.
const int kMinSamples = 3;

/// Speed ratio at or below which the pattern says "kẹt" (red).
const double kHistoryJamRatio = 0.5;

/// …and "chậm" (yellow). Above this the road is drawn normally.
const double kHistorySlowRatio = 0.75;

/// How congested (0 = free flow, 1 = crawling) the default route must be
/// predicted to be before the planner bothers looking for a better one. Below
/// this the roads are fine and switching routes would be churn.
const double kMinCongestionToSwap = 0.25;

/// An alternative must be at most this fraction of the default route's
/// predicted congestion to be chosen automatically (20 % better, not 2 %).
const double kBetterTrafficRoute = 0.8;

/// Fixes slower than this are stops (red light, red-light queue at a standstill,
/// phone in hand), not a property of the road, so they are not recorded.
const double kHistoryMinSpeedMps = 2.5;

/// One aggregate bucket.
class _Bucket {
  _Bucket(this.n, this.sumRatio);

  int n;
  double sumRatio;

  Map<String, Object> toJson() => {
    'n': n,
    'r': double.parse(sumRatio.toStringAsFixed(4)),
  };

  static _Bucket? fromJson(Object? v) {
    if (v is! Map) return null;
    final n = (v['n'] as num?)?.toInt() ?? 0;
    final r = (v['r'] as num?)?.toDouble() ?? 0;
    if (n <= 0) return null;
    return _Bucket(n, r);
  }
}

class TrafficHistory {
  /// key → bucket. Keys are `<latCell>,<lngCell>|<hour>|<wd|we>`.
  static final Map<String, _Bucket> _cells = {};
  static bool _loaded = false;
  static File? _defaultFileSync;

  @visibleForTesting
  static File? fileOverrideForTest;

  /// 1 Hz fixes would weight a slow crawl by how long the driver was stuck; the
  /// aggregate wants one sample per stretch of road, so fixes are sampled every
  /// [kHistoryFixStride] seconds of drive time.
  static const int kHistoryFixStride = 10;

  static int get cellCount => _cells.length;

  static void resetForTest() {
    _cells.clear();
    _loaded = false;
    _defaultFileSync = null;
    fileOverrideForTest = null;
  }

  static Future<File?> _file() async {
    final override = fileOverrideForTest;
    if (override != null) return override;
    if (kIsWeb) return null; // no disk: memory only for the session
    final cached = _defaultFileSync;
    if (cached != null) return cached;
    try {
      final sup = await getApplicationSupportDirectory();
      final f = File('${sup.path}/traffic_history.json');
      _defaultFileSync = f;
      return f;
    } catch (_) {
      return null;
    }
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return;
      final doc = jsonDecode(await f.readAsString());
      if (doc is! Map) return;
      final cells = doc['cells'];
      if (cells is! Map) return;
      for (final e in cells.entries) {
        final b = _Bucket.fromJson(e.value);
        if (b != null) _cells['${e.key}'] = b;
      }
      debugPrint('TRAFFIC HISTORY: ${_cells.length} ô đã nạp');
    } catch (e) {
      debugPrint('TRAFFIC HISTORY: load failed — $e');
    }
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'v': 1,
          'updated': DateTime.now().toIso8601String(),
          'cells': {for (final e in _cells.entries) e.key: e.value.toJson()},
        }),
      );
    } catch (e) {
      debugPrint('TRAFFIC HISTORY: save failed — $e');
    }
  }

  /// Grid cell of a position.
  static (int, int) cellOf(LatLng p) => (
    (p.latitude / kHistoryCellDeg).floor(),
    (p.longitude / kHistoryCellDeg).floor(),
  );

  /// Bucket key for a position at a moment.
  static String keyFor(LatLng p, DateTime at) {
    final (la, lo) = cellOf(p);
    final wd = at.weekday >= 6 ? 'we' : 'wd';
    return '$la,$lo|${at.hour}|$wd';
  }

  /// Fold one finished drive into the aggregate.
  ///
  /// Only fixes that carry BOTH a real speed and a posted limit are useful —
  /// without a limit there is nothing to be slow relative to. Returns the number
  /// of samples added.
  static Future<int> recordTrip(TripLogger trip) async {
    await load();
    final fixes = trip.fixes;
    if (fixes.length < 2) return 0;
    var added = 0;
    var lastAt = fixes.first.time;
    for (final f in fixes) {
      if (f.time.difference(lastAt).inSeconds < kHistoryFixStride) continue;
      lastAt = f.time;
      final limit = (f.limitEffective ?? f.speedLimit) ?? 0;
      if (limit <= 0) continue;
      if (f.speedMps < kHistoryMinSpeedMps) continue;
      final ratio = (f.speedMps / (limit / 3.6)).clamp(0.0, 1.6);
      final key = keyFor(LatLng(f.lat, f.lng), f.time.toLocal());
      final b = _cells[key];
      if (b == null) {
        _cells[key] = _Bucket(1, ratio);
      } else {
        b.n += 1;
        b.sumRatio += ratio;
      }
      added++;
    }
    if (added > 0) {
      await _save();
      debugPrint('TRAFFIC HISTORY: +$added mẫu từ "${trip.name}"');
    }
    return added;
  }

  /// Mean speed ratio recorded for this spot at this hour, or null when the
  /// device has not driven it enough times to say ([kMinSamples]).
  static double? ratioAt(
    LatLng p,
    DateTime at, {
    int minSamples = kMinSamples,
  }) {
    final b = _cells[keyFor(p, at)];
    if (b == null || b.n < minSamples) return null;
    return b.sumRatio / b.n;
  }

  static TrafficLevel? levelFor(double? ratio) {
    if (ratio == null) return null;
    if (ratio <= kHistoryJamRatio) return TrafficLevel.jam;
    if (ratio <= kHistorySlowRatio) return TrafficLevel.slow;
    return TrafficLevel.normal;
  }

  /// Predicted traffic for a route at [at], or null when the device has no
  /// pattern for it at all (a fresh install, or a road never driven).
  ///
  /// The estimate's duration is scaled by the mean predicted ratio in the SAME
  /// way a live provider reports one, so the "+18 phút" chip and the ETA work
  /// unchanged — they only need [RouteTraffic].
  static Future<RouteTraffic?> forRoute(
    List<LatLng> geometry, {
    required DateTime at,
    double? freeFlowSeconds,
    int minSamples = kMinSamples,
  }) async {
    await load();
    if (geometry.length < 2) return null;
    final levels = <TrafficLevel?>[];
    for (final p in geometry) {
      levels.add(levelFor(ratioAt(p, at, minSamples: minSamples)));
    }
    if (levels.every((l) => l == null)) return null;

    // Consecutive equal levels → one run. A null (unknown) vertex inherits its
    // neighbour so a single missing cell does not cut a jam in half.
    final spans = <TrafficSpan>[];
    var start = 0;
    var cur = levels.first;
    for (var i = 1; i < levels.length; i++) {
      final l = levels[i] ?? levels[i - 1];
      if (l == cur) continue;
      if (cur != null && cur != TrafficLevel.normal && i > start) {
        spans.add(TrafficSpan(start: start, end: i, level: cur));
      }
      start = i;
      cur = l;
    }
    if (cur != null && cur != TrafficLevel.normal && geometry.length > start) {
      spans.add(TrafficSpan(start: start, end: geometry.length, level: cur));
    }

    // Duration: every slow run costs its share of the route at the recorded
    // speed; jam runs cost more. 1.0 = free flow.
    var weighted = 0.0;
    var counted = 0;
    for (final s in spans) {
      for (var i = s.start; i < s.end && i < levels.length; i++) {
        final r = ratioAt(geometry[i], at, minSamples: minSamples);
        if (r == null || r <= 0.05) continue;
        weighted += 1 / r;
        counted++;
      }
    }
    final factor = counted == 0 ? 1.0 : weighted / counted;
    final free = freeFlowSeconds ?? 0;
    final liveS = free > 0 ? (free * factor).round() : 0;
    return RouteTraffic(
      live: Duration(seconds: liveS),
      freeFlow: Duration(seconds: free.round()),
      spans: spans,
      measuredAt: at,
      forTime: at,
      estimated: true,
    );
  }

  /// How congested this route is predicted to be, 0 = free flow, higher =
  /// worse. Used to compare alternatives offline (`candidate.mostlyJammed`).
  static Future<double> congestionScore(
    List<LatLng> geometry, {
    required DateTime at,
    int minSamples = kMinSamples,
  }) async {
    await load();
    if (geometry.length < 2) return 0;
    var sum = 0.0;
    var n = 0;
    for (final p in geometry) {
      final r = ratioAt(p, at, minSamples: minSamples);
      if (r == null) continue;
      sum += (1 - r).clamp(0.0, 1.0);
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }
}
