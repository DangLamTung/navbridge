/// A plate governs the traffic it FACES, and it stands on the right verge of
/// that traffic. Both halves matter at a khu dân cư boundary, where the pack
/// carries one plate per direction a few metres apart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_scan.dart';

class _Point implements OfflinePoint {
  const _Point(this.pos, this.heading);

  @override
  final LatLng pos;
  final double? heading;
}

void main() {
  const north = [LatLng(10.0, 106.7), LatLng(10.01, 106.7)];
  const start = LatLng(10.0, 106.7);

  test('a plate counts only when it faces the way the car travels', () {
    expect(signFacesTravel(signHeading: 0, travelBearing: 0), isTrue);
    expect(signFacesTravel(signHeading: 350, travelBearing: 10), isTrue);
    expect(signFacesTravel(signHeading: 180, travelBearing: 0), isFalse);
    expect(signFacesTravel(signHeading: 120, travelBearing: 0), isFalse);
  });

  test('routeBearingAt follows the polyline, not the compass', () {
    const south = [LatLng(10.01, 106.7), LatLng(10.0, 106.7)];
    expect(routeBearingAt(north, const LatLng(10.005, 106.7)), closeTo(0, 1));
    expect(routeBearingAt(south, const LatLng(10.005, 106.7)), closeTo(180, 1));
  });

  test('a boundary pair: only the plate facing our way survives the scan', () {
    final items = <_Point>[
      const _Point(LatLng(10.005, 106.7003), 0), // ours, right verge
      const _Point(LatLng(10.005, 106.6997), 180), // opposite direction
      const _Point(LatLng(10.006, 106.7003), null), // ours, no heading
      const _Point(LatLng(10.006, 106.6997), null), // left verge, no heading
    ];
    final kept = pointsAheadOnRoute<_Point>(
      (start, north, items, 1500, 40),
      rightSideFor: (_) => true,
      facingFor: (p) => p.heading,
    );
    expect(kept.map((e) => e.$1), [0, 2]);
  });

  test('an "80" on a town-entry post is dropped; the exit one is kept', () {
    RoadSign speed(double lat, double lng, double heading) => RoadSign(
      name: 'Hạn chế tốc độ 80 km/h',
      lat: lat,
      lng: lng,
      kind: RoadSignKind.speed,
      value: 80,
      source: 'vietmap',
      heading: heading,
    );
    RoadSign populated(double lat, double lng, double heading) => RoadSign(
      name: 'Khu đông dân cư',
      lat: lat,
      lng: lng,
      kind: RoadSignKind.populated,
      value: 40,
      source: 'vietmap',
      heading: heading,
    );
    RoadSign populatedEnd(double lat, double lng, double heading) => RoadSign(
      name: 'Hết khu đông dân cư',
      lat: lat,
      lng: lng,
      kind: RoadSignKind.populatedEnd,
      source: 'vietmap',
      heading: heading,
    );
    final signs = <RoadSign>[
      populated(10.0, 106.70, 90),
      speed(10.0, 106.7001, 90), // same post, same facing → dropped
      speed(10.0002, 106.70, 270), // our 80 going the other way → kept
      populatedEnd(10.01, 106.70, 90),
      speed(10.01, 106.7001, 90), // leaving town: a real 80 → kept
    ];
    final kept = dropSpeedPlatesOnBuiltUpPosts(signs);
    expect(kept.length, 4);
    expect(
      kept.where((s) => s.kind == RoadSignKind.speed).length,
      2,
      reason: 'only the town-START 80 goes',
    );
  });
}
