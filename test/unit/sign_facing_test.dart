/// Boundary plates on the map: one marker per corner, and a speed plate that
/// is really the zone's sign is not a second limit.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_road_signs.dart';

void main() {
  test('a boundary pair draws as ONE marker, not start + end side by side', () {
    RoadSign z(RoadSignKind k, double lat, double lng, {double? h}) => RoadSign(
      name: k.label,
      lat: lat,
      lng: lng,
      kind: k,
      source: 'vietmap',
      heading: h,
    );
    final signs = <RoadSign>[
      z(RoadSignKind.populated, 10.0, 106.70), // no heading
      z(RoadSignKind.populatedEnd, 10.0, 106.7003, h: 180), // 33 m away
      z(RoadSignKind.populated, 10.005, 106.70), // its own transition, 550 m on
      z(RoadSignKind.noPassing, 10.0, 106.7001),
    ];
    final out = collapseBoundaryPairs(signs);
    expect(out.length, 3, reason: 'the pair collapses, the rest stay');
    // The representative keeps the row that carries a heading.
    expect(out.first.heading, 180);
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
