/// OFFLINE traffic pattern + the yellow/red split.
///
/// Two behaviours pinned here:
///
///  * Google never emits `TRAFFIC_JAM` in Việt Nam two-wheeler coverage
///    (measured 2026-10-31, midday and a predicted 18:00 rush hour: one `SLOW`
///    run, no jam), so a `SLOW` run that carries a large share of the route's
///    lost time must be drawn RED — otherwise the map has one warning colour
///    and cannot say "crawling" at all.
///  * the device's own recorded drives (speed ÷ posted limit per cell per hour)
///    must colour a route with no network and no API key.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/route_traffic.dart';
import 'package:navbridge/services/traffic_history.dart';
import 'package:navbridge/services/trip_logger.dart';

int secs(String s) => int.parse(s.replaceAll('s', ''));

/// One point per ~278 m — i.e. one per history cell, so each vertex is its own
/// sample instead of six fixes sharing a single cell.
List<LatLng> line(int n) =>
    List<LatLng>.generate(n, (i) => LatLng(10.0 + i * 0.0025, 106.7));

void main() {
  group('grade — SLOW into yellow and red', () {
    test('a SLOW run carrying the whole delay is a JAM', () {
      // 100 vertices; the slow run is HALF the route and the route loses
      // 20 minutes over 20 free-flow minutes → implied speed ≈ 0.5×.
      final geo = line(101);
      final spans = [
        const TrafficSpan(start: 0, end: 50, level: TrafficLevel.normal),
        const TrafficSpan(start: 50, end: 101, level: TrafficLevel.slow),
      ];
      final graded = RouteTraffic.grade(
        spans,
        geo,
        delaySeconds: 20 * 60,
        freeFlowSeconds: 20 * 60,
      );
      expect(graded.last.level, TrafficLevel.jam, reason: 'di chậm >40% ⇒ đỏ');
    });

    test('a SLOW run with a small delay stays yellow', () {
      final geo = line(101);
      final spans = [
        const TrafficSpan(start: 0, end: 90, level: TrafficLevel.normal),
        const TrafficSpan(start: 90, end: 101, level: TrafficLevel.slow),
      ];
      final graded = RouteTraffic.grade(
        spans,
        geo,
        delaySeconds: 60,
        freeFlowSeconds: 40 * 60,
      );
      expect(graded.last.level, TrafficLevel.slow, reason: 'chậm nhẹ ⇒ vàng');
    });

    test('no delay in the response keeps Google\'s band untouched', () {
      final geo = line(20);
      final graded = RouteTraffic.grade(
        const [TrafficSpan(start: 0, end: 20, level: TrafficLevel.slow)],
        geo,
        delaySeconds: 0,
        freeFlowSeconds: 600,
      );
      expect(graded.single.level, TrafficLevel.slow);
    });

    test('a JAM band is never downgraded', () {
      final geo = line(20);
      final graded = RouteTraffic.grade(
        const [TrafficSpan(start: 0, end: 20, level: TrafficLevel.jam)],
        geo,
        delaySeconds: 0,
        freeFlowSeconds: 600,
      );
      expect(graded.single.level, TrafficLevel.jam);
    });

    test('both colours can appear on one route', () {
      final geo = line(101);
      final graded = RouteTraffic.grade(
        const [
          TrafficSpan(start: 10, end: 20, level: TrafficLevel.slow),
          TrafficSpan(start: 70, end: 100, level: TrafficLevel.slow),
        ],
        geo,
        delaySeconds: 30 * 60,
        freeFlowSeconds: 10 * 60,
      );
      final levels = graded.map((s) => s.level).toSet();
      expect(levels.contains(TrafficLevel.jam), isTrue);
    });
  });

  group('TrafficHistory', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('traffic-hist');
      TrafficHistory.resetForTest();
      TrafficHistory.fileOverrideForTest = File('${tmp.path}/h.json');
    });

    tearDown(() {
      TrafficHistory.resetForTest();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// A REAL drive shape: 1 Hz fixes along the line at [mps], because that is
    /// how the recorder writes them — several samples land in one cell, which
    /// is what [kMinSamples] is guarding.
    TripLogger driveAlong(
      List<LatLng> pts,
      DateTime at, {
      required double mps,
      int limit = 50,
    }) {
      final t = TripLogger(name: 'test', startedAt: at);
      var elapsed = 0;
      for (var i = 0; i < pts.length - 1; i++) {
        final a = pts[i];
        final b = pts[i + 1];
        final dy = (b.latitude - a.latitude) * 111320.0;
        final dx =
            (b.longitude - a.longitude) *
            111320.0 *
            math.cos(a.latitude * math.pi / 180);
        final segM = math.sqrt(dx * dx + dy * dy);
        final steps = math.max(1, (segM / mps).round());
        for (var s = 0; s < steps; s++) {
          final f = s / steps;
          t.fixes.add(
            TripFix(
              time: at.add(Duration(seconds: elapsed + s)),
              lat: a.latitude + (b.latitude - a.latitude) * f,
              lng: a.longitude + (b.longitude - a.longitude) * f,
              accuracyM: 5,
              speedMps: mps,
              heading: 0,
              source: 'SIM',
              limitEffective: limit,
            ),
          );
        }
        elapsed += steps;
      }
      return t;
    }

    test('a crawl becomes a red run, a fast road stays normal', () {
      // ~1.1 km southbound; 12 km/h against a 50 limit ⇒ ratio 0.24.
      final pts = line(6);
      final at = DateTime(2026, 10, 31, 17, 30); // Saturday 17:30
      final t = driveAlong(pts, at, mps: 12 / 3.6);

      return TrafficHistory.recordTrip(t).then((n) async {
        expect(n, greaterThan(10), reason: 'one sample per 10 s, not per fix');
        final level = TrafficHistory.levelFor(
          TrafficHistory.ratioAt(pts[0], at),
        );
        expect(level, TrafficLevel.jam);

        final rt = await TrafficHistory.forRoute(
          pts,
          at: at,
          freeFlowSeconds: 80,
        );
        expect(rt, isNotNull);
        expect(rt!.estimated, isTrue, reason: 'a forecast, not a live feed');
        expect(rt.spans, isNotEmpty);
        expect(rt.spans.first.level, TrafficLevel.jam);
      });
    });

    test('free-flowing traffic colours nothing', () {
      final pts = line(6);
      final at = DateTime(2026, 10, 31, 12, 0);
      final t = driveAlong(pts, at, mps: 45 / 3.6);
      return TrafficHistory.recordTrip(t).then((_) async {
        final rt = await TrafficHistory.forRoute(
          pts,
          at: at,
          freeFlowSeconds: 80,
        );
        expect(
          rt,
          isNull,
          reason: 'nothing to say ⇒ no traffic reading at all',
        );
      });
    });

    test('one drive is not a pattern', () {
      // One quick pass: ~1 sample per cell, under kMinSamples.
      final pts = line(3);
      final at = DateTime(2026, 10, 31, 8, 0);
      return TrafficHistory.recordTrip(driveAlong(pts, at, mps: 30)).then((_) {
        expect(
          TrafficHistory.ratioAt(pts[0], at),
          isNull,
          reason: 'needs kMinSamples before it may colour anything',
        );
      });
    });

    test('the hour matters — 08:00 is not 12:00', () {
      final pts = line(6);
      return TrafficHistory.recordTrip(
        driveAlong(pts, DateTime(2026, 10, 31, 8, 0), mps: 5),
      ).then((_) {
        expect(
          TrafficHistory.ratioAt(pts[0], DateTime(2026, 10, 31, 12, 0)),
          isNull,
        );
        expect(
          TrafficHistory.ratioAt(pts[0], DateTime(2026, 10, 31, 8, 20)),
          isNotNull,
        );
      });
    });

    test('the pattern survives a reload from disk', () {
      final pts = line(6);
      final at = DateTime(2026, 10, 31, 17, 0);
      return TrafficHistory.recordTrip(driveAlong(pts, at, mps: 12 / 3.6)).then(
        (_) async {
          final before = TrafficHistory.ratioAt(pts[0], at);
          final file = TrafficHistory.fileOverrideForTest!;
          final override = file;
          TrafficHistory.resetForTest();
          TrafficHistory.fileOverrideForTest = override;
          await TrafficHistory.load();
          expect(before, isNotNull);
          expect(TrafficHistory.ratioAt(pts[0], at), closeTo(before!, 1e-6));
        },
      );
    });

    test('congestionScore separates a jammed route from a free one', () {
      final jam = line(6);
      final at = DateTime(2026, 10, 31, 18, 0);
      return TrafficHistory.recordTrip(driveAlong(jam, at, mps: 12 / 3.6)).then(
        (_) async {
          final jamScore = await TrafficHistory.congestionScore(jam, at: at);
          expect(jamScore, greaterThan(kMinCongestionToSwap));
          // A route 1° away has no history at all ⇒ no predicted congestion.
          final far = line(6).map((p) => LatLng(p.latitude + 1, p.longitude));
          expect(await TrafficHistory.congestionScore(far.toList(), at: at), 0);
        },
      );
    });
  });
}
