import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_scan_isolate.dart';

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
    expect(cams, isNotEmpty);
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
    expect(cams, isNotEmpty);
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
    expect(cams, isNotEmpty);
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

  test('mostImportantCameraAhead prefers red-light/speed over nearer '
      'surveillance', () {
    OfflineCamera cam(String? type, String focus, double lat, double lng) =>
        OfflineCamera(
          name: 'Camera',
          lat: lat,
          lng: lng,
          focus: focus,
          type: type,
          source: 'vietmap',
        );
    // A surveillance camera 60 m ahead must NOT shadow the red-light camera
    // 200 m ahead — 76% of the DB is surveillance, so nearest-first made the
    // useful warning lose.
    final surveillance = CameraAhead(
      camera: cam('traffic_camera', 'violations', 10.0, 106.0),
      routeMeters: 60,
    );
    final redLight = CameraAhead(
      camera: cam('red_light_camera', 'red_light', 10.01, 106.0),
      routeMeters: 200,
    );
    final speed = CameraAhead(
      camera: cam('speed_camera', 'speed', 10.02, 106.0),
      routeMeters: 260,
    );
    expect(
      mostImportantCameraAhead([surveillance, redLight, speed])!.camera.type,
      'red_light_camera',
    );

    // Same type → the nearest still wins (no pointless jump to a far one).
    final far = CameraAhead(
      camera: cam('speed_camera', 'speed', 10.0, 106.0),
      routeMeters: 500,
    );
    final near = CameraAhead(
      camera: cam('speed_camera', 'speed', 10.01, 106.0),
      routeMeters: 120,
    );
    expect(mostImportantCameraAhead([far, near])!.routeMeters, 120);

    // Untyped police rows fall back to their focus (violations = lowest).
    final police = CameraAhead(
      camera: OfflineCamera(
        name: 'Camera',
        lat: 10.0,
        lng: 106.0,
        focus: 'violations',
        source: 'police',
      ),
      routeMeters: 30,
    );
    expect(
      mostImportantCameraAhead([police, redLight])!.camera.type,
      'red_light_camera',
    );
    expect(mostImportantCameraAhead(const []), isNull);
  });

  test('dedupCameraAhead collapses same-focus cameras within ~100 m', () {
    OfflineCamera cam(
      String focus,
      double lat,
      double lng, {
      String src = 'waze',
    }) => OfflineCamera(
      name: 'Camera',
      lat: lat,
      lng: lng,
      focus: focus,
      source: src,
    );
    // Same focus (speed), ~50 m apart → 1 (cross-source duplicate).
    expect(
      dedupCameraAhead([
        CameraAhead(camera: cam('speed', 10.7695, 106.6930), routeMeters: 10),
        CameraAhead(camera: cam('speed', 10.7699, 106.6934), routeMeters: 60),
      ]),
      hasLength(1),
    );
    // Different focus at the same spot (speed + red_light) → both kept.
    expect(
      dedupCameraAhead([
        CameraAhead(camera: cam('speed', 10.7695, 106.6930), routeMeters: 10),
        CameraAhead(
          camera: cam('red_light', 10.7695, 106.6930),
          routeMeters: 10,
        ),
      ]),
      hasLength(2),
    );
    // Same focus but far apart (>100 m) → both kept.
    expect(
      dedupCameraAhead([
        CameraAhead(camera: cam('speed', 10.7695, 106.6930), routeMeters: 10),
        CameraAhead(camera: cam('speed', 10.7900, 106.6930), routeMeters: 400),
      ]),
      hasLength(2),
    );
  });

  test('dedupCameras collapses same-focus cameras within ~100 m', () {
    OfflineCamera cam(String focus, double lat, double lng) => OfflineCamera(
      name: 'Camera',
      lat: lat,
      lng: lng,
      focus: focus,
      source: 'waze',
    );
    // Same focus, ~50 m apart → 1.
    expect(
      dedupCameras([
        cam('violations', 10.7695, 106.6930),
        cam('violations', 10.7699, 106.6934),
      ]),
      hasLength(1),
    );
    // Different focus at one spot → both kept.
    expect(
      dedupCameras([
        cam('speed', 10.7695, 106.6930),
        cam('red_light', 10.7695, 106.6930),
      ]),
      hasLength(2),
    );
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
