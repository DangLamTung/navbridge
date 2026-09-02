import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_speed_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the bundled nationwide speed-limit layer', () async {
    await loadOfflineSpeedLimits();
    expect(speedLimitsLoaded, isTrue);
  });

  test('returns a real posted limit near crawled city roads', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      return; // real DB is local-only (CI ships empty stub files)
    }
    // Points on DATMAP-crawled roads (validated against the merged dataset).
    const probes = [
      ('Hanoi', 105.8342, 21.0278),
      ('Hue', 107.5907, 16.4637),
      ('Nha Trang', 109.1967, 12.2388),
      ('HCMC', 106.6607, 10.7627),
    ];
    var any = false;
    for (final (name, lon, lat) in probes) {
      final limit = await speedLimitAt(LatLng(lat, lon));
      // The point may be a few tens of metres off a crawled segment — that is
      // fine (returns null); when it DOES resolve, the limit must be sane.
      if (limit != null) {
        any = true;
        expect(limit, inInclusiveRange(5, 200), reason: name);
      }
    }
    // At least one of the probed city points must resolve to a real limit.
    expect(any, isTrue, reason: 'no crawled road resolved near city probes');
  });

  test(
    'querying exactly ON a crawled segment resolves its own limit',
    () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        return; // real DB is local-only (CI ships empty stub files)
      }
      // Sample segments straight from the bundled GeoJSON; a query at the first
      // vertex must resolve to a plausible limit (we are standing on the road).
      final raw = await rootBundle.loadString(
        'assets/offline_map/vietnam_speed_limits.geojson',
      );
      final fc = jsonDecode(raw) as Map<String, dynamic>;
      final features = (fc['features'] as List).cast<Map<String, dynamic>>();
      var resolved = 0;
      for (final f in features.take(500)) {
        final line =
            (((f['geometry'] as Map<String, dynamic>)['coordinates']
                        as List?) ??
                    const [])
                .cast<List<dynamic>>();
        if (line.isEmpty) continue;
        final props = (f['properties'] as Map<String, dynamic>? ?? const {});
        final fwd = (props['fwdMaxSpeed'] ?? 0) as num;
        final rev = (props['revMaxSpeed'] ?? 0) as num;
        if (fwd <= 0 && rev <= 0) continue; // no posted limit -> null expected
        final lon = (line.first[0] as num).toDouble();
        final lat = (line.first[1] as num).toDouble();
        final limit = await speedLimitAt(LatLng(lat, lon));
        if (limit != null) {
          resolved++;
          expect(limit, inInclusiveRange(5, 200));
        }
      }
      // The overwhelming majority of on-segment probes must resolve.
      expect(resolved, greaterThan(300), reason: 'on-segment lookups missing');
    },
  );

  test('far off-map returns null (no invented limits)', () async {
    await loadOfflineSpeedLimits();
    // Deep in the Pacific, far outside any crawled tile.
    final limit = await speedLimitAt(const LatLng(5.0, 160.0));
    expect(limit, isNull);
  });
}
