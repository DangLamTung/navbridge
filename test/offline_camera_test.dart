import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled camera index', () async {
    final cams = await loadOfflineCameras();
    expect(cams, isNotEmpty);
    // Every camera has valid Vietnam coordinates + a focus.
    for (final c in cams) {
      expect(c.lat, inInclusiveRange(8.0, 23.6));
      expect(c.lng, inInclusiveRange(102.0, 110.0));
      expect(['speed', 'red_light', 'violations', 'sign'], contains(c.focus));
      expect(c.name, isNotEmpty);
    }
  });

  test('camerasAheadOnRoute returns ordered ahead cameras', () async {
    final cams = await loadOfflineCameras();
    if (cams.isEmpty) return; // guard if asset missing in test env
    // A route through the middle of TP Hà Giang (where cameras cluster).
    final geometry = [
      const LatLng(22.80, 104.97),
      const LatLng(22.81, 104.98),
      const LatLng(22.82, 104.98),
      const LatLng(22.83, 104.99),
      const LatLng(22.84, 105.00),
    ];
    final ahead = await camerasAheadOnRoute(
      const LatLng(22.80, 104.97),
      geometry,
      maxAheadMeters: 5000,
    );
    // Must be sorted by route distance ascending.
    for (var i = 1; i < ahead.length; i++) {
      expect(
        ahead[i].routeMeters,
        greaterThanOrEqualTo(ahead[i - 1].routeMeters),
      );
    }
    // All returned cameras are >= 0m ahead (not behind the car).
    for (final a in ahead) {
      expect(a.routeMeters, greaterThanOrEqualTo(0));
    }
  });

  test('camerasNearRoute returns only cameras on/near the route', () async {
    final cams = await loadOfflineCameras();
    if (cams.isEmpty) return;
    // A short route through the middle of TP Hà Giang (camera cluster). The
    // corridor is 200 m either side of the polyline.
    final geometry = [
      const LatLng(22.80, 104.97),
      const LatLng(22.81, 104.98),
      const LatLng(22.82, 104.98),
      const LatLng(22.83, 104.99),
    ];
    final near = await camerasNearRoute(geometry);
    // Must be a strict subset (a few cameras on the route, not all 1,800).
    expect(near.length, lessThan(cams.length));
    expect(near.length, greaterThan(0));
    for (final c in near) {
      // Every returned camera projects within 200 m of the polyline.
      expect(_minDistanceToLine(geometry, c.pos), lessThanOrEqualTo(200));
    }
  });

  test('camerasNearRoute returns empty for an empty/short route', () async {
    expect(await camerasNearRoute(const []), isEmpty);
    expect(await camerasNearRoute(const [LatLng(22.8, 104.97)]), isEmpty);
  });

  test('camera index covers 60+ provinces (Vietnam-wide)', () async {
    final cams = await loadOfflineCameras();
    if (cams.isEmpty) return;
    // Every camera carries a province/district tag (from the build pipeline).
    final tagged = cams.where((c) => (c.district ?? '').isNotEmpty);
    // The vast majority must be tagged; the DB covers 60/63 provinces after
    // the nationwide crawl (only Lai Châu skipped by design).
    expect(tagged.length, greaterThan(cams.length * 0.6));
    final provinces = tagged.map((c) => c.district).toSet();
    expect(provinces.length, greaterThanOrEqualTo(55));
    // Spot-check a few regions the crawl filled recently.
    for (final p in [
      'Hải Phòng',
      'Nam Định',
      'Gia Lai',
      'Vĩnh Long',
      'Lâm Đồng',
    ]) {
      expect(
        tagged.where((c) => c.district == p),
        isNotEmpty,
        reason: '$p should have cameras after the crawl',
      );
    }
  });
}

/// Minimum straight-line distance (metres) from [p] to the polyline [geo] —
/// test-side helper to double-check the corridor filter. Uses the same
/// degree-space projection as the service (`_projectOnSegment`), then measures
/// the true geodesic distance.
double _minDistanceToLine(List<LatLng> geo, LatLng p) {
  const d = Distance();
  var best = double.infinity;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude, py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    LatLng proj;
    if (len2 == 0) {
      proj = a;
    } else {
      final t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
      proj = LatLng(ay + t * dy, ax + t * dx);
    }
    final off = d.as(LengthUnit.Meter, proj, p);
    if (off < best) best = off;
  }
  return best;
}
