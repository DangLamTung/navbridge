import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/heading_filter.dart';

/// [StrictHeading] with the `headingSource` option (Settings → Dẫn đường).
///
/// `'travel'` (default) derives the heading from the last two fixes and holds it
/// below the 2 m movement threshold; `'phone'` trusts the heading the receiver
/// reports with the fix. The heading is not cosmetic: the posted-limit segment
/// layer picks a segment's `fwd`/`rev` value from it and decides with it whether
/// the car is RIDING the segment.
void main() {
  /// ~1.1 m of north per 1e-5 deg of latitude.
  LatLng at(double metresNorth) => LatLng(10.79 + metresNorth / 111320.0, 106.63);

  test('travel: sub-2 m movement HOLDS, so it needs the phone to move first', () {
    final f = StrictHeading();
    f.update(180, at(0)); // first fix: seeds from the receiver (180 = south)
    // 1 m north between fixes is below the 2 m threshold → no travel bearing,
    // so the heading stays on the seeded 180.
    expect(f.update(180, at(1)), 180);
  });

  test('phone: a reported heading is used even while crawling', () {
    final f = StrictHeading();
    f.update(300, at(0));
    // 1 m of movement: 'travel' has nothing, 'phone' has the receiver's 305.
    expect(f.update(305, at(1), preferPhone: true), 305);
  });

  test('phone: falls back to the travel bearing when the fix has no heading', () {
    final f = StrictHeading();
    f.update(0, at(0));
    // 10 m due north → travel bearing ~0. The receiver reports NaN (no bearing
    // yet), so 'phone' must not throw the direction away.
    final h = f.update(double.nan, at(10), preferPhone: true);
    expect(h, isNotNull);
    expect(h! < 1 || h > 359, isTrue, reason: 'roughly due north, got $h');
  });

  test('phone: one large jump does not spin the arrow (2 agreeing fixes)', () {
    final f = StrictHeading();
    f.update(10, at(0), preferPhone: true);
    // A single 180° flip is held …
    expect(f.update(190, at(5), preferPhone: true), 10);
    // … and applied once a second fix agrees.
    expect(f.update(191, at(10), preferPhone: true), 191);
  });

  test('travel: the same value would have been applied immediately', () {
    // Proves the guard is the SHARED one and the modes differ only in the
    // candidate they feed it: a 30° change is a normal turn and applies at once.
    final f = StrictHeading();
    f.update(0, at(0));
    expect(f.update(30, at(10), preferPhone: true), 30);
  });
}
