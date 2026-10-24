/// A Waze/VietMap posted value is a CAR limit. For a mô tô it is evidence about
/// the ROAD FORM, not a number to copy:
///
///   outside a built-up area  ô tô 80 (hai chiều) / 90 (đường đôi)
///   inside  a built-up area  ô tô 50 (hai chiều) / 60 (đường đôi)
///
/// so a 70 says "two-way road" (mô tô 60) and a town 60 says "đường đôi" (mô tô
/// 60 too). Both directions of the 50/60 swap came from ignoring that (user,
/// 2026-10-24: "waze nó kêu 70 tức là tốc độ chỗ đó ô tô 70 … xe máy phải là 60
/// chứ đéo phải 70", "chỗ 50 thì m bảo 60 chỗ 60 thì m bảo 50").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/overpass.dart';

void main() {
  test('Waze 70 on a rural road is a CAR value: mô tô 60', () {
    // The graph reads every divided carriageway as a one-way way, and
    // `dividedForm` counts a one-way way as ≥2 lanes — so this used to come out
    // as the divided-road 70.
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 70,
        postedSrc: srcSegment,
        oneway: true,
      ),
      60,
    );
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 70,
        postedSrc: srcSegment,
        oneway: false,
      ),
      60,
    );
    // 80 is the car's own hai-chiều row: still the mô tô 60.
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 80,
        postedSrc: srcSegment,
        oneway: true,
      ),
      60,
    );
    // 90 is not a car's two-way number, so it still proves a divided road.
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 90,
        postedSrc: srcSegment,
        oneway: true,
      ),
      70,
    );
  });

  test('in town a layer value still may only TIGHTEN the mô tô limit', () {
    // A town 60 can be a đường-đôi value OR a posted 60 sign on a hai-chiều
    // street, so the layer is not used to lift a bike off its 50 — that rule is
    // measured (103 fixes across 56 recorded drives) and stays.
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 60,
        postedSrc: srcSegment,
        urban: true,
        oneway: false,
      ),
      50,
    );
    // …while a town 50 is the hai-chiều number either way.
    expect(
      effectiveLimit(
        'primary',
        vehicle: 'motorbike',
        taggedKmh: 50,
        postedSrc: srcSegment,
        urban: true,
        oneway: false,
      ),
      50,
    );
  });

  test('the road chip takes the same decision (applyPostedLayer)', () {
    final rural = roadInfoFromRoad(
      name: 'Quốc lộ 1A',
      highway: 'primary',
      vehicle: 'motorbike',
      oneway: false,
    );
    expect(
      applyPostedLayer(
        rural,
        kmh: 70,
        vehicle: 'motorbike',
        layerSrc: srcSegment,
        inTown: false,
      ).speedLimit,
      60,
      reason: 'Waze 70 = ô tô 70 trên đường hai chiều ⇒ xe máy 60',
    );

    // The SAME value on a divided road the app can actually evidence keeps the
    // bike's legal 70 (Điều 8 TT31/2019: đường đôi 70).
    final divided = roadInfoFromRoad(
      name: 'Quốc lộ 1A',
      highway: 'primary',
      vehicle: 'motorbike',
      divided: true,
    );
    expect(
      applyPostedLayer(
        divided,
        kmh: 70,
        vehicle: 'motorbike',
        layerSrc: srcSegment,
        inTown: false,
      ).speedLimit,
      70,
    );
  });

  test('a car still gets the posted value it was given', () {
    expect(effectiveLimit('primary', vehicle: 'car', taggedKmh: 70), 70);
    expect(effectiveLimit('primary', vehicle: 'car', taggedKmh: 60), 60);
  });
}
