import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('camerasNearRoute is fast on a 191km route (no ANR)', () async {
    // Synthetic ~191 km polyline (~1 point per 10 m) from HCMC to Bao Loc.
    final geo = <LatLng>[];
    const lat0 = 10.77, lng0 = 106.69, lat1 = 11.55, lng1 = 107.81;
    const n = 19000;
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      geo.add(LatLng(lat0 + (lat1 - lat0) * t, lng0 + (lng1 - lng0) * t));
    }
    final sw = Stopwatch()..start();
    final near = await camerasNearRoute(geo);
    sw.stop();
    // ignore: avoid_print
    print(
      'BENCH: camerasNearRoute on 191km route: '
      '${sw.elapsedMilliseconds}ms, ${near.length} cameras',
    );
    // Generous bound (original code blocked the UI thread for ~34 s on this
    // workload — 1,800 cameras × 19,000 polyline points on the main isolate).
    // 8 s still catches a regression (~4× below the 34 s failure) without
    // flaking when the full suite runs test files in parallel and saturates
    // the CPU (the wall clock ~2.5× slows under concurrent load).
    expect(sw.elapsedMilliseconds, lessThan(8000));
  });
}
