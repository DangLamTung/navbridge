/// The POI search ranking is a BLEND: the closest few first ("what's near me"),
/// then what lies on the route ahead ("what I'll reach"), then the rest.
///
/// Before this, ranking was route-only, so a station 200 m away that sat just
/// off the polyline sank below one 8 km ahead — which reads as "the search is
/// ignoring what's right here". Pure nearest had the opposite flaw ("xăng gần
/// nhất" pointing back the way we came).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/poi_search.dart';

/// A straight northbound route, ~4.4 km, car 1 km up it.
final _route = [
  for (var i = 0; i < 40; i++) LatLng(10.0 + i * 0.001, 106.0),
];
const _car = LatLng(10.010, 106.0);
const _type = PoiType.fuel;

PoiResult _poi(String name, double lat, double lng) =>
    PoiResult(name: name, lat: lat, lng: lng, type: _type);

void main() {
  test('nearest few first, then the ones on the route ahead', () {
    // 0.001° lat ≈ 111 m.
    final onRoute1km = _poi('on-route 1km', 10.019, 106.0); // ahead on the line
    final onRoute3km = _poi('on-route 3km', 10.037, 106.0);
    final beside200m = _poi('beside 200m', 10.0106, 106.0018); // ~200 m off-line
    final behind = _poi('behind', 10.006, 106.0); // behind the car, on the line

    final ranked = rankPoisBlended(
      [onRoute3km, behind, beside200m, onRoute1km],
      carPos: _car,
      route: _route,
      nearestCount: 3,
    );

    // Tier 1 = the 3 closest straight-line, nearest first. NOTE: this group can
    // contain a place BEHIND the car ("behind", 444 m) — that is the requested
    // "show me what's near me"; the route tier below is what separates "what I
    // will actually reach".
    expect(ranked.map((r) => r.poi.name).toList(), [
      'beside 200m', // ~208 m, just off the line
      'behind', // ~444 m, on the line but behind the car
      'on-route 1km', // ~1000 m, on the line ahead
      'on-route 3km', // ~3000 m: outside the nearest group → the route tier
    ]);
    expect(
      ranked.take(3).every((r) => r.relevance == PoiRelevance.nearest),
      isTrue,
    );
    // Tier 2 = what is left that sits ON the route ahead.
    expect(ranked.last.poi.name, 'on-route 3km');
    expect(ranked.last.relevance, PoiRelevance.onRoute);
    expect(ranked.last.aheadMeters, closeTo(3000, 60));
  });

  test('a place off to the side is NOT "on route", however far ahead it is', () {
    // 2 km ahead but 400 m off the polyline: the driver cannot reach it without
    // leaving the route, so the route tier must not claim it (corridor 150 m).
    final offSide = _poi('off-side 2km ahead', 10.028, 106.0036);
    final ranked = rankPoisBlended(
      [offSide, _poi('near', 10.011, 106.0), _poi('near2', 10.012, 106.0)],
      carPos: _car,
      route: _route,
      nearestCount: 1,
    );
    final off = ranked.firstWhere((r) => r.poi.name == 'off-side 2km ahead');
    expect(off.relevance, PoiRelevance.other);
    expect(off.aheadMeters, isNull); // outside the corridor
  });

  test('every result appears exactly once (no tier leaks)', () {
    final pois = [
      for (var i = 1; i <= 8; i++) _poi('p$i', 10.0 + i * 0.002, 106.0),
    ];
    final ranked = rankPoisBlended(
      pois,
      carPos: _car,
      route: _route,
      nearestCount: 3,
    );
    expect(ranked.length, pois.length);
    expect(ranked.map((r) => r.poi.name).toSet().length, pois.length);
  });

  test('no route yet: plain nearest-first, nothing claimed as on-route', () {
    final ranked = rankPoisBlended(
      [
        _poi('far', 10.05, 106.0),
        _poi('close', 10.011, 106.0),
      ],
      carPos: _car,
      nearestCount: 3,
    );
    expect(ranked.map((r) => r.poi.name).toList(), ['close', 'far']);
    expect(ranked.every((r) => r.aheadMeters == null), isTrue);
  });

  test('the shown distance for an on-route place is the driven distance', () {
    final ranked = rankPoisBlended(
      [_poi('ahead', 10.019, 106.0)],
      carPos: _car,
      route: _route,
      nearestCount: 3,
    );
    // Straight-line and along-route agree on a straight line; the point is that
    // displayMeters uses the along-route value when there is one.
    expect(ranked.single.displayMeters, closeTo(1000, 30));
    expect(ranked.single.aheadMeters, closeTo(1000, 30));
  });

  test('empty in, empty out', () {
    expect(rankPoisBlended(const [], carPos: _car), isEmpty);
  });
}
