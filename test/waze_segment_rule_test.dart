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
