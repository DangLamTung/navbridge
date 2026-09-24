/// Signs the driver has already passed must go — and must come back when the
/// heading does.
///
/// User, 2026-09-24: "sign behind the car can be remove, but when turn back must
/// show". [signsAheadOfDriver] is that rule: a heading test against the CURRENT
/// direction of travel, so turning back down the same road re-admits the very
/// same signs without any state to reset.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_road_signs.dart';

RoadSign _sign(double lat, double lng, [RoadSignKind? kind]) => RoadSign(
  kind: kind ?? RoadSignKind.stop,
  lat: lat,
  lng: lng,
  value: null,
  name: '',
  source: 'test',
);

void main() {
  // Car at the origin, heading NORTH.
  const car = LatLng(10.000000, 106.000000);
  // ~111 m north (ahead), ~111 m south (behind), ~111 m east (to the side).
  final ahead = _sign(10.001000, 106.000000);
  final behind = _sign(9.999000, 106.000000);
  final side = _sign(10.000000, 106.001000);

  test('a sign ahead is kept, one already passed is removed', () {
    final kept = signsAheadOfDriver([ahead, behind, side],
        car: car, headingDeg: 0);
    expect(kept, contains(ahead));
    expect(kept, isNot(contains(behind)));
  });

  test('turning back re-admits the sign that was behind', () {
    // Same list, same car — heading 180 (south) instead of 0 (north).
    final kept = signsAheadOfDriver([ahead, behind, side],
        car: car, headingDeg: 180);
    expect(kept, contains(behind), reason: 'now it is in front');
    expect(kept, isNot(contains(ahead)));
  });

  test('a sign square to the side is kept while heading past it, dropped once '
      'the heading puts it behind', () {
    // Due east of the car: neutral at heading 0/180 (along ≈ 0), in front at
    // 90, and 111 m BEHIND at 270 — the last one is a passed sign like any
    // other, so it goes.
    expect(signsAheadOfDriver([side], car: car, headingDeg: 0), contains(side));
    expect(signsAheadOfDriver([side], car: car, headingDeg: 180), contains(side));
    expect(signsAheadOfDriver([side], car: car, headingDeg: 90), contains(side));
    expect(signsAheadOfDriver([side], car: car, headingDeg: 270),
        isNot(contains(side)));
  });

  test('the sign being passed right now is kept until it is 40 m back', () {
    final justBehind = _sign(9.999900, 106.000000); // ~12 m south
    final farBehind = _sign(9.999500, 106.000000); // ~55 m south
    final kept = signsAheadOfDriver([justBehind, farBehind],
        car: car, headingDeg: 0);
    expect(kept, contains(justBehind));
    expect(kept, isNot(contains(farBehind)));
  });

  test('a diagonal sign counts by its component along the heading', () {
    // ~111 m east AND ~111 m north of the car: firmly in front at heading 45,
    // squarely behind at 225.
    final northEast = _sign(10.001000, 106.001000);
    expect(signsAheadOfDriver([northEast], car: car, headingDeg: 45),
        contains(northEast));
    expect(signsAheadOfDriver([northEast], car: car, headingDeg: 225),
        isNot(contains(northEast)));
  });
}
