import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/layer_hold.dart';

/// The bounded memory behind "may I keep the layer's value although the lookup
/// just missed?".
///
/// The bug it exists to kill (user, 2026-10-10): "move from 60 km have waze
/// segment to no waze segment still not correct, last trip still have the 60
/// even after moved to new place" — the held value outlived the coverage it came
/// from, because the hold had no distance bound.
void main() {
  const at = LatLng(10.8000, 106.6400);

  /// [meters] north of [at] — 1 deg of latitude is ~111,320 m.
  LatLng north(double meters) =>
      LatLng(at.latitude + meters / 111320.0, at.longitude);

  test('nothing is held before the layer has answered', () {
    expect(LayerHold().fresh('Lũy Bán Bích', at), isFalse);
  });

  test('a held value survives a momentary miss on the same road', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Lũy Bán Bích', north(2)), isTrue);
    expect(h.fresh('Lũy Bán Bích', north(20)), isTrue);
  });

  test('the longest hold a real drive needed is still held', () {
    // Measured with tool/hold_audit.py over 66 recorded drives: the layer can
    // have no record within 25 m for up to 145 m while the car is still on the
    // covered road (Lũy Bán Bích, 2026-10-08 17:40 drive). Breaking that hold
    // would flicker the chip to the class default mid-road.
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Lũy Bán Bích', north(145)), isTrue);
    expect(h.fresh('Lũy Bán Bích', north(299)), isTrue);
  });

  test('the hold EXPIRES once the car has driven past maxMeters', () {
    expect(
      LayerHold().fresh('x', at),
      isFalse,
      reason: 'sanity: an unanswered hold is never fresh',
    );
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(
      h.fresh('Lũy Bán Bích', north(301)),
      isFalse,
      reason: 'the 60 of a covered stretch must let go of a road the layer '
          'does not cover',
    );
  });

  test('the bound is configurable', () {
    final h = LayerHold(maxMeters: 50);
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Lũy Bán Bích', north(49)), isTrue);
    expect(h.fresh('Lũy Bán Bích', north(51)), isFalse);
  });

  test('every hit re-anchors, so a covered stretch never looks stale', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    // 1 Hz fixes at 50 km/h: ~14 m apart, each answered by the layer.
    for (var driven = 0.0; driven < 1000; driven += 14) {
      h.note('Lũy Bán Bích', north(driven));
    }
    expect(
      h.fresh('Lũy Bán Bích', north(1000 + 100)),
      isTrue,
      reason: 'the 100 m since the LAST answer is what counts, not the 1000 m '
          'driven since the first',
    );
  });

  test('a stationary car keeps the hold — the hold is distance, not time', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Lũy Bán Bích', at), isTrue);
    expect(h.fresh('Lũy Bán Bích', north(0.5)), isTrue,
        reason: 'waiting at a junction is still the same road');
  });

  test('another road is never held', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Thống Nhất', north(5)), isFalse);
  });

  test('the spelling the driver reads does not break the hold', () {
    final h = LayerHold();
    // Same road, diacritic fold (the Cộng Hòa ⇄ Cộng Hoà case).
    h.note('Cộng Hòa', at);
    expect(h.fresh('Cộng Hoà', north(5)), isTrue);
  });

  test('forget() drops the hold for a new session', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    h.forget();
    expect(h.fresh('Lũy Bán Bích', north(1)), isFalse);
  });

  test('an unknown position still holds while the road is the same', () {
    final h = LayerHold();
    h.note('Lũy Bán Bích', at);
    expect(h.fresh('Lũy Bán Bích', null), isTrue);
  });
}
