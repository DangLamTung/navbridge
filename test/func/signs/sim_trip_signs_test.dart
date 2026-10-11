// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_road_signs.dart';

/// CI ships a STUBBED sign DB (tool/stub_assets.sh), so a sign-derived
/// assertion here must SKIP rather than fail on a clean checkout - the idiom
/// the rest of the sign suite already uses (road_signs_test.dart).
const _signDbStubNote = 'bundled sign DB is a stub (see tool/stub_assets.sh)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('simulate trip signs on route for long_39 (QL51 / Xa lộ Hà Nội)', () async {
    final signs = await loadOfflineRoadSigns();
    if (signs.isEmpty) {
      markTestSkipped(_signDbStubNote);
      return;
    }
    print('Total offline road signs loaded: ${signs.length}');

    final f = File('test/data/trips/long_39.json');
    expect(f.existsSync(), isTrue);

    final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final rawGeo = (d['geometry'] as List).cast<List<dynamic>>();
    final geo = [
      for (final p in rawGeo)
        LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    print('Trip long_39 geometry vertices: ${geo.length}, km: ${d['km']}');

    // Check signs along the route (as nav-map preview does)
    final routeSigns = await signsNearRoute(geo, corridorMeters: 60);
    print('Signs near route (corridor 60m): ${routeSigns.length}');
    final kinds = <String, int>{};
    for (final s in routeSigns) {
      kinds[s.kind.key] = (kinds[s.kind.key] ?? 0) + 1;
    }
    print('Signs by kind along long_39: $kinds');
    expect(routeSigns.length, greaterThan(10));

    // Simulate navigation: walk the route and check signs ahead
    var signsAheadFound = 0;
    for (var i = 0; i < geo.length; i += 50) {
      final cur = geo[i];
      final window = geo.sublist(i);
      if (window.length < 2) break;
      final ahead = await signsAheadOnRoute(cur, window, maxAheadMeters: 1000);
      if (ahead.isNotEmpty) {
        signsAheadFound += ahead.length;
      }
    }
    print('Total ahead sign detections across trip: $signsAheadFound');
    expect(signsAheadFound, greaterThan(0));
  });

  test('simulate trip signs on route for short_08 (5.8 km)', () async {
    if ((await loadOfflineRoadSigns()).isEmpty) {
      markTestSkipped(_signDbStubNote);
      return;
    }

    final f = File('test/data/trips/short_08.json');
    expect(f.existsSync(), isTrue);

    final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final rawGeo = (d['geometry'] as List).cast<List<dynamic>>();
    final geo = [
      for (final p in rawGeo)
        LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    print('Trip short_08 geometry vertices: ${geo.length}, km: ${d['km']}');

    final routeSigns = await signsNearRoute(geo, corridorMeters: 60);
    print('Signs near route (corridor 60m): ${routeSigns.length}');
    final kinds = <String, int>{};
    for (final s in routeSigns) {
      kinds[s.kind.key] = (kinds[s.kind.key] ?? 0) + 1;
    }
    print('Signs by kind along short_08: $kinds');
    expect(routeSigns, isNotEmpty);
  });
}
