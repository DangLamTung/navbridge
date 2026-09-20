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

  test('returns a real posted limit near a crawled point', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      return; // real DB is local-only (CI ships empty stub files)
    }
    // Probe a few metres off the first Waze point — the grid + radius lookup
    // must resolve a sane limit within the 25 m window.
    final raw = await rootBundle.loadString(
      'assets/offline_map/waze_speed_limits.json',
    );
    final d = jsonDecode(raw) as Map<String, dynamic>;
    final points = (d['points'] as List).cast<Map<String, dynamic>>();
    if (points.isEmpty) return;
    final p = points.first;
    final lat = (p['lat'] as num).toDouble();
    final lng = (p['lng'] as num).toDouble();
    final limit = await speedLimitAt(LatLng(lat + 0.00002, lng + 0.00002));
    expect(limit, isNotNull);
    expect(limit, inInclusiveRange(5, 200));
  });

  test(
    'querying exactly ON a posted Waze/VietMap point resolves its own limit',
    () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        return; // real DB is local-only (CI ships empty stub files)
      }
      // Sample points straight from the bundled Waze / VietMap files; a query
      // at the point's own coordinates must resolve to its own (sane) limit.
      var checked = 0;
      var resolved = 0;
      for (final name in [
        'waze_speed_limits.json',
        'vietmap_speed_limits.json',
      ]) {
        final raw = await rootBundle.loadString('assets/offline_map/$name');
        final d = jsonDecode(raw) as Map<String, dynamic>;
        final points = (d['points'] as List?) ?? const [];
        for (final p in points.take(500)) {
          final lat = (p['lat'] as num?)?.toDouble();
          final lng = (p['lng'] as num?)?.toDouble();
          final kmh = (p['kmh'] as num?)?.toDouble();
          if (lat == null || lng == null || kmh == null) continue;
          checked++;
          final limit = await speedLimitAt(LatLng(lat, lng));
          if (limit != null) {
            resolved++;
            expect(limit, inInclusiveRange(5, 200));
          }
        }
      }
      expect(checked, greaterThan(0));
      expect(resolved, greaterThan(0), reason: 'on-point lookups missing');
    },
  );

  test('far off-map returns null (no invented limits)', () async {
    await loadOfflineSpeedLimits();
    // Deep in the Pacific, far outside any crawled tile.
    final limit = await speedLimitAt(const LatLng(5.0, 160.0));
    expect(limit, isNull);
  });

  group('Waze WME per-segment layer', () {
    // Real coordinates from the 2026-09-14 HCMC trip log, each within a few
    // metres of a crawled Waze segment. The expected values were confirmed
    // independently by matching segments on the SAME street name (not just the
    // nearest segment — Waze's basemap geometry differs from OSM, so the
    // nearest-segment match agrees with the logged limit only ~29% of the time).
    test(
      'resolves the real posted limit on Lũy Bán Bích (đường đôi = 60)',
      () async {
        await loadOfflineSpeedLimits();
        if (!speedLimitsPopulated) return; // real DB is local-only
        // Lũy Bán Bích is a secondary split into two one-way carriageways with a
        // dải phân cách. Waze posts 60; the app used to DISPLAY 50 because a
        // built-up zone boundary capped it (that layer is gone — see
        // droppedSignKinds).
        final limit = await speedLimitAt(
          const LatLng(10.79571, 106.63825),
          headingDeg: 10,
        );
        expect(limit, 60);
      },
    );

    test('resolves Âu Cơ = 50 (two-way, no dải phân cách)', () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) return; // real DB is local-only
      // Âu Cơ is a TWO-WAY secondary with no median, so the built-up limit is
      // 50 — while the OSM class table alone says 60. This is exactly the case
      // the Waze segment layer fixes.
      final limit = await speedLimitAt(
        const LatLng(10.79697, 106.63789),
        headingDeg: 160,
      );
      expect(limit, 50);
    });

    test('resolves Ấp Bắc = 50 (residential)', () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) return; // real DB is local-only
      final limit = await speedLimitAt(const LatLng(10.80073, 106.64134));
      expect(limit, 50);
    });

    test('returns null far from any crawled segment', () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) return; // real DB is local-only
      // ~2 km north of the trip area, past the nearest crawled HCMC segment.
      expect(await speedLimitAt(const LatLng(10.83000, 106.66000)), isNull);
    });
  });
}
