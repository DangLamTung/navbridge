/// Only the sign standing on the RIGHT of the direction of travel governs this
/// traffic (QCVN 41:2019). The plate on the left belongs to the opposite
/// carriageway, and reading it is how the app announced — and adopted as the
/// limit — the other direction's number, which is the 50/60 that swaps either
/// way on a divided road (user, 2026-10-24: "biển nào m cũng đọc như con vẹt óc
/// lợn, trong khi biển có hiệu lực cần đọc là biển bên tay phải").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_scan.dart';

class _Point implements OfflinePoint {
  const _Point(this.pos);

  @override
  final LatLng pos;
}

void main() {
  // ~1.1 km of due-north road: the direction of travel is north, so EAST of the
  // line is the right-hand side and WEST is the left.
  const start = LatLng(10.0, 106.7);
  const north = [LatLng(10.0, 106.7), LatLng(10.01, 106.7)];

  test('signed offset: east of a northbound line is RIGHT, west is LEFT', () {
    final right = signedLateralOffsetMeters(
      north,
      const LatLng(10.005, 106.7001),
    );
    final left = signedLateralOffsetMeters(
      north,
      const LatLng(10.005, 106.6999),
    );
    expect(right, isNotNull);
    expect(left, isNotNull);
    expect(right!, greaterThan(0), reason: 'phía tay phải ⇒ dương');
    expect(left!, lessThan(0), reason: 'phía tay trái ⇒ âm');
    // Both are ~11 m off the centreline; the magnitude is the lateral distance.
    expect(right.abs(), closeTo(11, 1.5));
    expect(left.abs(), closeTo(11, 1.5));
  });

  test('the side follows the DIRECTION of the polyline, not the compass', () {
    // The same two points on a SOUTHBOUND line: east is now the driver's LEFT.
    const south = [LatLng(10.01, 106.7), LatLng(10.0, 106.7)];
    expect(
      signedLateralOffsetMeters(south, const LatLng(10.005, 106.7001))!,
      lessThan(0),
    );
    expect(
      signedLateralOffsetMeters(south, const LatLng(10.005, 106.6999))!,
      greaterThan(0),
    );
  });

  test('lateralOffsetMeters still reports the unsigned distance', () {
    expect(
      lateralOffsetMeters(north, const LatLng(10.005, 106.6999)),
      lateralOffsetMeters(north, const LatLng(10.005, 106.7001)),
    );
  });

  test(
    'the ahead scan drops the left-hand sign and keeps the right-hand one',
    () {
      final items = <_Point>[
        const _Point(LatLng(10.005, 106.7001)), // right verge  (~11 m)
        const _Point(LatLng(10.005, 106.6998)), // left verge   (~22 m)
        const _Point(LatLng(10.006, 106.7)), // snapped to the centreline
        const _Point(
          LatLng(10.007, 106.69999),
        ), // 1 m left — inside the tolerance
      ];
      final all = pointsAheadOnRoute<_Point>((start, north, items, 1500, 40));
      expect(all.length, 4, reason: 'without the rule every post is "ahead"');

      final rightOnly = pointsAheadOnRoute<_Point>((
        start,
        north,
        items,
        1500,
        40,
      ), rightSideFor: (_) => true);
      expect(rightOnly.map((e) => e.$1), [0, 2, 3]);
    },
  );

  test('a plate a few metres left (median / snapped row) still counts', () {
    // 3 m left of the centreline is a median-mounted or snapped row, not the
    // other carriageway — QL13 has nothing between −9.5 m and 0 m.
    final items = <_Point>[
      const _Point(LatLng(10.005, 106.69997)),
    ]; // ~3 m left
    final kept = pointsAheadOnRoute<_Point>((
      start,
      north,
      items,
      1500,
      40,
    ), rightSideFor: (_) => true);
    expect(kept.length, 1);
  });
}
