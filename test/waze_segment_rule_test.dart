/// Locks the app's Waze SEGMENT reader against the bundled asset.
///
/// Why: tool/waze_segments.py derived the per-direction value from the wrong
/// bearing (the whole segment end-to-end, instead of the nearest sub-segment in
/// stored node order) and inverted 95% of the asset's 25,127 per-direction
/// segments — an offline audit would then read the opposite carriageway's
/// limit. These cases pin the APP's rule to concrete records in the shipped
/// blob, so a reader or asset change that flips a direction fails loudly.
///
/// Coordinates and values come from tool/audit_waze_segments.py (which now
/// reproduces this reader exactly on 2,011 probe points).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_speed_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A stretch where Waze posts 50 in one direction and 60 in the other, and
  // where the stored node order runs due west (bearing 270°).
  const hongBang = LatLng(10.753340, 106.650690);
  // fwd 80 / rev 60, stored node order runs just east of north (bearing 12°).
  const leDucAnh = LatLng(10.812940, 106.600470);

  test('a per-direction segment answers the value for the heading given',
      () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) return; // CI ships stub assets

    // Heading along the stored node order ⇒ the `fwd` value.
    expect(await speedLimitAt(hongBang, headingDeg: 270), 50);
    expect(lastLimitLayer(), 'segment');
    expect(await speedLimitAt(leDucAnh, headingDeg: 12), 80);
    expect(lastLimitLayer(), 'segment');

    // Opposite heading ⇒ the `rev` value. A reader that used the segment's
    // end-to-end bearing instead would return these two swapped.
    expect(await speedLimitAt(hongBang, headingDeg: 90), 60);
    expect(await speedLimitAt(leDucAnh, headingDeg: 192), 60);

    // No heading ⇒ the higher of the two, as a limit ceiling.
    expect(await speedLimitAt(hongBang), 60);
    expect(await speedLimitAt(leDucAnh), 80);
  });

  test('the winning segment names the road that supplied the limit', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) return;
    await speedLimitAt(hongBang, headingDeg: 270);
    expect(lastWazeStreetName(), 'Hồng Bàng');
    await speedLimitAt(leDucAnh, headingDeg: 12);
    expect(lastWazeStreetName(), 'Lê Đức Anh');
  });

  test('the pick holds the value on screen between parallel records', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) return;
    // Cộng Hòa carries TWO parallel records a few metres apart, with different
    // values and names that fold to the same string ('cong hoa'): id=601376
    // 60 km/h and id=603315 50 km/h. Whichever is nearest alternated with the
    // GPS noise and the chip swapped 60/50 every second (2026-09-22 20:48
    // drive, 27 same-road value changes). This coordinate+heading is one where
    // the plain pick takes the 50 and would have flipped the display.
    const congHoa = LatLng(10.800843, 106.660801);
    expect(await speedLimitAt(congHoa, headingDeg: 277), 50);
    expect(lastWazeStreetName(), 'Cộng Hòa');
    // 60 is on screen and a 60 record is right there → stay.
    expect(await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 60), 60);
    // A value nothing nearby carries must not be invented.
    expect(await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 80), 50);
    // With the band closed the plain pick returns (no unconditional stickiness).
    expect(
      await speedLimitAt(congHoa, headingDeg: 277, keepKmh: 60, keepBandM: 0),
      50,
    );
  });

  test('a lookup that finds no segment must not name a road', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) return;
    // Đắk Lắk highlands: no segment within 25 m, and no point pin nearby.
    await speedLimitAt(hongBang, headingDeg: 270);
    expect(lastWazeStreetName(), isNotNull); // warm the global first

    final kmh = await speedLimitAt(const LatLng(12.0, 108.2), headingDeg: 270);
    expect(kmh, isNull);
    // The caller adopts this name verbatim when the limit is null, so an empty
    // answer here is what stops a stray segment renaming the road.
    expect(lastWazeStreetName(), isNull);
  });
}
