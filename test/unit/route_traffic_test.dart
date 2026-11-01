/// Live-traffic reading: parsing, the ETA delta, and slicing jam runs for the
/// two map renderers.
///
/// The payloads below mirror real Routes API responses (probed 2026-10-29
/// against `computeRoutes` with `TRAFFIC_ON_POLYLINE`): durations are strings
/// like "1649s", and `speedReadingIntervals` are `start..end` polyline index
/// ranges where `end` is EXCLUSIVE — a 559-point polyline ends its last
/// interval at 558.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/route_traffic.dart';
import 'package:navbridge/ui/traffic_overlay.dart';

int secs(String s) {
  final m = RegExp(r'^(\d+)s$').firstMatch(s.trim());
  return m == null ? 0 : int.parse(m.group(1)!);
}

List<LatLng> line(int n) =>
    List<LatLng>.generate(n, (i) => LatLng(10.0 + i * 0.0001, 106.7));

void main() {
  group('RouteTraffic.fromGoogle', () {
    test('reads the jam runs and both durations', () {
      final geo = line(100);
      // 60 s of delay, so the grading pass leaves Google's bands alone (the
      // yellow→red split is covered in traffic_history_test.dart).
      final t = RouteTraffic.fromGoogle(
        {
          'duration': '960s',
          'staticDuration': '900s',
          'travelAdvisory': {
            'speedReadingIntervals': [
              {
                'startPolylinePointIndex': 0,
                'endPolylinePointIndex': 40,
                'speed': 'NORMAL',
              },
              {
                'startPolylinePointIndex': 40,
                'endPolylinePointIndex': 70,
                'speed': 'SLOW',
              },
              {
                'startPolylinePointIndex': 70,
                'endPolylinePointIndex': 100,
                'speed': 'TRAFFIC_JAM',
              },
            ],
          },
        },
        geo,
        seconds: secs,
      );

      expect(t, isNotNull);
      expect(t!.live.inSeconds, 960);
      expect(t.freeFlow.inSeconds, 900);
      expect(t.delaySeconds, 60);
      expect(t.delayed, isTrue);
      expect(t.delayLabel, '+1 phút');
      expect(t.jams.map((s) => s.level), [TrafficLevel.slow, TrafficLevel.jam]);
      expect(t.jams.first.start, 40);
      expect(t.jams.first.end, 70);
    });

    test('free-flow traffic is not a delay', () {
      final t = RouteTraffic.fromGoogle(
        {
          'duration': '600s',
          'staticDuration': '900s',
          'travelAdvisory': {
            'speedReadingIntervals': [
              {
                'startPolylinePointIndex': 0,
                'endPolylinePointIndex': 99,
                'speed': 'NORMAL',
              },
            ],
          },
        },
        line(100),
        seconds: secs,
      );

      expect(t!.delayed, isFalse, reason: 'faster than free flow is not a jam');
      expect(t.delayLabel, '');
      expect(t.jams, isEmpty);
      expect(t.hasJams, isFalse);
    });

    test('a malformed index cannot escape the geometry', () {
      final t = RouteTraffic.fromGoogle(
        {
          'duration': '60s',
          'staticDuration': '60s',
          'travelAdvisory': {
            'speedReadingIntervals': [
              {
                'startPolylinePointIndex': 90,
                'endPolylinePointIndex': 999999,
                'speed': 'TRAFFIC_JAM',
              },
              {
                'startPolylinePointIndex': 500,
                'endPolylinePointIndex': 600,
                'speed': 'SLOW',
              },
            ],
          },
        },
        line(100),
        seconds: secs,
      );

      expect(t, isNotNull);
      for (final s in t!.spans) {
        expect(s.start, greaterThanOrEqualTo(0));
        expect(s.end, lessThanOrEqualTo(100));
      }
    });

    test('no durations at all is null, not a zero-length traffic reading', () {
      expect(RouteTraffic.fromGoogle({}, line(10), seconds: secs), isNull);
    });
  });

  group('trafficRouteSpans', () {
    OsrmRoute routeWith(List<TrafficSpan> spans, {int points = 100}) =>
        OsrmRoute(
          distance: 1000,
          duration: 60,
          geometry: line(points),
          steps: const [],
          traffic: RouteTraffic(
            live: const Duration(seconds: 600),
            freeFlow: const Duration(seconds: 300),
            spans: spans,
          ),
        );

    test('slices the raw geometry, keeping both ends of a run', () {
      final route = routeWith([
        const TrafficSpan(start: 10, end: 20, level: TrafficLevel.jam),
      ]);
      final out = trafficRouteSpans(route);
      expect(out.length, 1);
      expect(out.first.level, TrafficLevel.jam);
      // end is exclusive → indices 10..19 → 10 points
      expect(out.first.points.length, 10);
      expect(out.first.points.first, route.geometry[10]);
      expect(out.first.points.last, route.geometry[19]);
    });

    test('normal runs are not painted', () {
      final route = routeWith([
        const TrafficSpan(start: 0, end: 99, level: TrafficLevel.normal),
      ]);
      expect(trafficRouteSpans(route), isEmpty);
    });

    test('a route with no traffic reading paints nothing', () {
      final plain = OsrmRoute(
        distance: 1000,
        duration: 60,
        geometry: line(10),
        steps: const [],
      );
      expect(trafficRouteSpans(plain), isEmpty);
      expect(trafficRouteSpans(null), isEmpty);
    });

    test('colours follow the level', () {
      final route = routeWith([
        const TrafficSpan(start: 0, end: 5, level: TrafficLevel.jam),
        const TrafficSpan(start: 5, end: 10, level: TrafficLevel.slow),
      ]);
      final out = trafficRouteSpans(route);
      expect(out[0].color.toARGB32(), const Color(0xFFD32F2F).toARGB32());
      expect(out[1].color.toARGB32(), const Color(0xFFF9A825).toARGB32());
    });
  });

  group('RouteTraffic.remap', () {
    test('anchors a jam onto another provider\'s geometry', () {
      final from = line(100); // 0 .. 0.0099° north
      final to = line(100);
      final spans = RouteTraffic.remap(
        const [TrafficSpan(start: 40, end: 50, level: TrafficLevel.jam)],
        from,
        to,
        fromMeters: 1000,
        toMeters: 1000,
      );
      expect(spans.length, 1);
      expect(spans.first.level, TrafficLevel.jam);
      expect(spans.first.start, greaterThanOrEqualTo(0));
      expect(spans.first.end, greaterThan(spans.first.start));
      expect(spans.first.end, lessThanOrEqualTo(to.length));
      // around the midpoint (45) of the original run
      expect(spans.first.start, closeTo(45, 6));
    });

    test('degenerate inputs produce no spans instead of throwing', () {
      expect(RouteTraffic.remap(const [], const [], const []), isEmpty);
      expect(
        RouteTraffic.remap(
          const [TrafficSpan(start: 0, end: 1, level: TrafficLevel.jam)],
          const [LatLng(10, 106)],
          const [LatLng(10, 106)],
        ),
        isEmpty,
      );
    });
  });
}
