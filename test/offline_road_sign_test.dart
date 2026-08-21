import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_road_signs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled road-sign index', () async {
    final signs = await loadOfflineRoadSigns();
    expect(signs, isNotEmpty);
    for (final s in signs) {
      expect(s.lat, inInclusiveRange(8.0, 23.6));
      expect(s.lng, inInclusiveRange(102.0, 110.0));
      expect(s.name, isNotEmpty);
      expect(RoadSignKind.values, contains(s.kind));
    }
  });

  test('index covers all sign kinds', () async {
    final signs = await loadOfflineRoadSigns();
    if (signs.isEmpty) return;
    final kinds = signs.map((s) => s.kind).toSet();
    // The Vietnam dataset has traffic lights, stop, give-way, speed-limit,
    // "đông dân cư" signs and the VN-standard prohibitions (cấm vượt, cấm rẽ,
    // cấm quay đầu, hết mọi lệnh cấm).
    expect(kinds, contains(RoadSignKind.signal));
    expect(kinds, contains(RoadSignKind.stop));
    expect(kinds, contains(RoadSignKind.speed));
    expect(kinds, contains(RoadSignKind.populated));
    expect(kinds, contains(RoadSignKind.populatedEnd));
    expect(kinds, contains(RoadSignKind.noPassing));
    expect(kinds, contains(RoadSignKind.noLeftTurn));
    expect(kinds, contains(RoadSignKind.noRightTurn));
    expect(kinds, contains(RoadSignKind.noUTurn));
    expect(kinds, contains(RoadSignKind.endProhibitions));
    // Speed signs carry a usable km/h value for the sign icon.
    for (final s in signs.where((s) => s.kind == RoadSignKind.speed)) {
      expect(s.value, isNotNull);
      expect(s.value, inInclusiveRange(5, 200));
    }
  });

  test('signsAheadOnRoute returns ordered signs ahead', () async {
    final signs = await loadOfflineRoadSigns();
    if (signs.isEmpty) return;
    // A short route through central HCMC (Bến Thành → D1), dense with
    // traffic lights.
    final geometry = [
      const LatLng(10.7695, 106.6930),
      const LatLng(10.7730, 106.6990),
      const LatLng(10.7760, 106.7040),
      const LatLng(10.7790, 106.7090),
    ];
    final ahead = await signsAheadOnRoute(
      const LatLng(10.7695, 106.6930),
      geometry,
      maxAheadMeters: 3000,
    );
    for (var i = 1; i < ahead.length; i++) {
      expect(
        ahead[i].routeMeters,
        greaterThanOrEqualTo(ahead[i - 1].routeMeters),
      );
    }
    for (final a in ahead) {
      expect(a.routeMeters, greaterThanOrEqualTo(0));
      expect(a.routeMeters, lessThanOrEqualTo(3000));
    }
  });

  test('signsNearRoute returns only signs on/near the route', () async {
    final signs = await loadOfflineRoadSigns();
    if (signs.isEmpty) return;
    final geometry = [
      const LatLng(10.7695, 106.6930),
      const LatLng(10.7730, 106.6990),
      const LatLng(10.7760, 106.7040),
      const LatLng(10.7790, 106.7090),
    ];
    final near = await signsNearRoute(geometry);
    expect(near.length, lessThan(signs.length));
    expect(near.length, greaterThan(0));
    for (final s in near) {
      expect(_minDistanceToLine(geometry, s.pos), lessThanOrEqualTo(200));
    }
  });

  test('signsNearRoute returns empty for an empty/short route', () async {
    expect(await signsNearRoute(const []), isEmpty);
    expect(await signsNearRoute(const [LatLng(10.77, 106.70)]), isEmpty);
  });

  test('signsAheadOnRoute returns empty for an empty/short route', () async {
    expect(
      await signsAheadOnRoute(const LatLng(10.77, 106.70), const []),
      isEmpty,
    );
  });
}

/// Minimum straight-line distance (metres) from [p] to the polyline [geo] —
/// test-side helper (same degree-space projection as the service).
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
      var t = ((px - ax) * dx + (py - ay) * dy) / len2;
      t = t.clamp(0.0, 1.0);
      proj = LatLng(ay + t * dy, ax + t * dx);
    }
    final dist = d.as(LengthUnit.Meter, proj, p);
    if (dist < best) best = dist;
  }
  return best;
}
