/// Times the main-thread route-build steps with a LONG synthetic route
/// (200k geometry points ≈ a 1000+ km route) to find which step freezes the
/// app. Run: flutter test tool/route_bench.dart (or dart run).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_scan.dart';
import 'package:navbridge/services/offline_scan_isolate.dart';
import 'package:navbridge/services/osrm.dart';

List<LatLng> _longRoute() {
  final pts = <LatLng>[];
  // ~200k points over ~1000 km (a point every ~5 m)
  for (var i = 0; i < 200000; i++) {
    pts.add(LatLng(10.8 + i * 0.000045, 106.6 + i * 0.000045));
  }
  return pts;
}

OsrmRoute _routeOf(List<LatLng> geo) => OsrmRoute(
  distance: 1000000,
  duration: 36000,
  geometry: geo,
  steps: [
    OsrmStep(
      name: 'start',
      distance: 1000000,
      duration: 36000,
      type: 'depart',
      modifier: null,
      maneuver: const LatLng(10.8, 106.6),
    ),
  ],
  stopCumulative: const [1000000],
);

void main() {
  test('long-route build steps', () {
    final geo = _longRoute();
    final route = _routeOf(geo);
    const d = Distance();

    var t0 = DateTime.now();
    final cum = <double>[0];
    var c = 0.0;
    for (var i = 1; i < geo.length; i++) {
      c += fastDistanceMeters(geo[i - 1], geo[i]);
      cum.add(c);
    }
    var t1 = DateTime.now();
    // ignore: avoid_print
    print('engine _cum build (fast): ${t1.difference(t0).inMilliseconds}ms');

    t0 = DateTime.now();
    for (var i = 1; i < geo.length; i++) {
      c += d.as(LengthUnit.Meter, geo[i - 1], geo[i]);
    }
    t1 = DateTime.now();
    // ignore: avoid_print
    print('cumulative haversine:     ${t1.difference(t0).inMilliseconds}ms');

    t0 = DateTime.now();
    final dec = decimatePolyline(geo);
    t1 = DateTime.now();
    // ignore: avoid_print
    print(
      'decimatePolyline(200k):   ${t1.difference(t0).inMilliseconds}ms '
      '(-> ${dec.length} pts)',
    );

    t0 = DateTime.now();
    final eng = TurnByTurnEngine(route);
    t1 = DateTime.now();
    // ignore: avoid_print
    print('TurnByTurnEngine build:   ${t1.difference(t0).inMilliseconds}ms');

    t0 = DateTime.now();
    for (var i = 0; i < 1000; i++) {
      // Drive ALONG the route (on-road, the common case) — index advances.
      eng.update(geo[(i * 50) % geo.length], speedMps: 15);
    }
    t1 = DateTime.now();
    // ignore: avoid_print
    print('1000x engine.update():    ${t1.difference(t0).inMilliseconds}ms');

    t0 = DateTime.now();
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (final p in geo) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    t1 = DateTime.now();
    // ignore: avoid_print
    print('bounds scan (fromPoints): ${t1.difference(t0).inMilliseconds}ms');
  });

  test(
    'REAL 1246km OSRM route end-to-end (http + compute + parse)',
    () async {
      final t0 = DateTime.now();
      final routes = await fetchOsrmRoutes(const [
        LatLng(13.7659, 106.6501),
        LatLng(21.0278, 105.8342),
      ]);
      final t1 = DateTime.now();
      // ignore: avoid_print
      print(
        'fetchOsrmRoutes total: '
        '${t1.difference(t0).inMilliseconds}ms, '
        'routes=${routes.length}, '
        'geom=${routes.first.geometry.length}, '
        'steps=${routes.first.steps.length}',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'per-second camera check: compute round-trip with real DB + 13k geo',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final raw = await rootBundle.loadString(
        'assets/offline_map/vietnam_cameras.json',
      );
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cams = [
        for (final it
            in (data['cameras'] as List? ?? const [])
                .cast<Map<String, dynamic>>())
          OfflineCamera.fromJson(it),
      ];
      // Real 1246 km route geometry (decoded) from the earlier fetch, plus
      // a synthetic 13k-point geometry as fallback.
      final geo = _longRoute().sublist(0, 13000);
      // ignore: avoid_print
      print('cams=${cams.length} geo=${geo.length}');

      // Warm up the isolate.
      await compute(pointsAheadOnRoute<OfflineCamera>, (
        geo.first,
        geo,
        cams,
        1500.0,
      ));

      final t0 = DateTime.now();
      for (var i = 0; i < 10; i++) {
        await compute(pointsAheadOnRoute<OfflineCamera>, (
          geo.first,
          geo,
          cams,
          1500.0,
        ));
      }
      final t1 = DateTime.now();
      // ignore: avoid_print
      print(
        'pointsAheadOnRoute (13k geo x ${cams.length} cams): '
        '${t1.difference(t0).inMilliseconds}ms / 10 = '
        '${t1.difference(t0).inMilliseconds / 10}ms each',
      );

      final t2 = DateTime.now();
      for (var i = 0; i < 10; i++) {
        await compute(pointsNearRoute<OfflineCamera>, (geo, cams, 200.0));
      }
      final t3 = DateTime.now();
      // ignore: avoid_print
      print(
        'pointsNearRoute  (13k geo x ${cams.length} cams): '
        '${t3.difference(t2).inMilliseconds}ms / 10 = '
        '${t3.difference(t2).inMilliseconds / 10}ms each',
      );

      // NEW: persistent-isolate path (DB transferred ONCE, then only args).
      final svc = OfflineScanIsolate.instance;
      final t4 = DateTime.now();
      for (var i = 0; i < 10; i++) {
        await svc.camerasAhead(geo.first, geo, maxAheadMeters: 1500);
      }
      final t5 = DateTime.now();
      // ignore: avoid_print
      print(
        'persistent-isolate camerasAhead x10: '
        '${t5.difference(t4).inMilliseconds}ms / 10 = '
        '${t5.difference(t4).inMilliseconds / 10}ms each',
      );

      final t6 = DateTime.now();
      for (var i = 0; i < 10; i++) {
        await svc.camerasNear(geo, corridorMeters: 200);
      }
      final t7 = DateTime.now();
      // ignore: avoid_print
      print(
        'persistent-isolate camerasNear  x10: '
        '${t7.difference(t6).inMilliseconds}ms / 10 = '
        '${t7.difference(t6).inMilliseconds / 10}ms each',
      );

      // MAIN-THREAD BLOCK measurement: a 1 ms timer can't tick while the main
      // isolate is busy copying/serializing. Count missed ticks during the
      // awaited calls — that's the real ANR cost.
      Future<double> mainThreadBlockMs(
        Future<void> Function() run,
        Duration wall,
      ) async {
        var ticks = 0;
        final t = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => ticks++,
        );
        final w0 = DateTime.now();
        await run();
        final w = DateTime.now().difference(w0);
        // ignore: avoid_print
        print(
          '    main-thread: ${w.inMilliseconds}ms wall, '
          '$ticks ticks of ~1ms fired → '
          '~${w.inMilliseconds - ticks}ms busy (vs ${wall.inMilliseconds}ms '
          'isolate wall)',
        );
        t.cancel();
        return (w.inMilliseconds - ticks).toDouble();
      }

      // ignore: avoid_print
      print('old compute (DB re-sent every call):');
      await mainThreadBlockMs(() async {
        for (var i = 0; i < 10; i++) {
          await compute(pointsAheadOnRoute<OfflineCamera>, (
            geo.first,
            geo,
            cams,
            1500.0,
          ));
        }
      }, const Duration(milliseconds: 830));

      // ignore: avoid_print
      print('persistent isolate (DB sent once):');
      await mainThreadBlockMs(() async {
        for (var i = 0; i < 10; i++) {
          await svc.camerasAhead(geo.first, geo, maxAheadMeters: 1500);
        }
      }, const Duration(milliseconds: 910));

      // CORRECTNESS: persistent-isolate results must EXACTLY match the old
      // compute path (same index + routeMeters) — the fix must be a no-op
      // behaviourally, only faster.
      final cur = geo[5000];
      final oldRes = await compute(pointsAheadOnRoute<OfflineCamera>, (
        cur,
        geo,
        cams,
        1500.0,
      ));
      final newRes = await svc.camerasAhead(cur, geo, maxAheadMeters: 1500);
      expect(
        newRes.length,
        oldRes.length,
        reason: 'same number of ahead cameras',
      );
      for (var i = 0; i < oldRes.length; i++) {
        expect(
          newRes[i].camera.name,
          cams[oldRes[i].$1].name,
          reason: 'camera #$i matches old path',
        );
        expect(
          (newRes[i].routeMeters - oldRes[i].$2).abs() < 0.001,
          true,
          reason: 'routeMeters #$i matches old path',
        );
      }
      // ignore: avoid_print
      print(
        'CORRECTNESS: persistent-isolate == old compute ('
        '${oldRes.length} ahead cameras) ✓',
      );

      final oldNear = await compute(pointsNearRoute<OfflineCamera>, (
        geo,
        cams,
        200.0,
      ));
      final newNear = await svc.camerasNear(geo, corridorMeters: 200);
      expect(newNear.length, oldNear.length, reason: 'same near count');
      for (var i = 0; i < oldNear.length; i++) {
        expect(
          newNear[i].name,
          cams[oldNear[i]].name,
          reason: 'near camera #$i matches',
        );
      }
      // ignore: avoid_print
      print(
        'CORRECTNESS: camerasNear persistent-isolate == old compute '
        '(${oldNear.length} near cameras) ✓',
      );

      // HOW MANY cameras/signs does a REAL long Vietmap route produce for the
      // map layer? (the nav map draws 4 maplibre circles PER camera + every
      // sign as an icon overlay — the count drives the "large zoom is slow"
      // issue). Uses the real HCMC→Hà Nội Vietmap geometry.
      final f = File('/tmp/vmroute.json');
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final paths = (data['paths'] as List?) ?? const [];
        final geo = decodePolyline(
          ((paths.first as Map<String, dynamic>)['points'] ?? '') as String,
        );
        // ignore: avoid_print
        print('VIETMAP route geom=${geo.length} pts');
        final camsNear = await svc.camerasNear(geo, corridorMeters: 200);
        final signs = await loadOfflineRoadSigns();
        final signsNear = await compute(pointsNearRoute<RoadSign>, (
          geo,
          signs,
          500.0,
        ));
        // ignore: avoid_print
        print(
          'VIETMAP near-route: ${camsNear.length} cameras ×4 circles = '
          '${camsNear.length * 4} maplibre annotations; '
          '${signsNear.length} signs as icon overlays',
        );
      }
      svc.dispose();
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );
}
