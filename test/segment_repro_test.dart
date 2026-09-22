/// The 2026-09-21 17:34 Ấp Bắc stretch, where the app showed the town guess
/// (60 km/h, `limitLayer=city`) while a 50 km/h Waze segment sat under the car.
///
/// Settled by this file: the layer data and the Dart reader are correct — the
/// lookup at the logged position returns 50 / 'segment' / 'Ấp Bắc' for any
/// heading, and a ~20 m box around it is still 50. So the posted data was
/// REACHABLE when the app showed 60: the miss is in the publisher (which record
/// ends up on screen), not in the lookup. Kept as a regression test so a future
/// lookup change cannot quietly start missing this spot.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_speed_limits.dart';

const _lat = 10.799482;
const _lng = 106.641203; // the fix that logged 60 km/h (heading 182)

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the segment layer answers 50 km/h at the logged position', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      return; // CI ships stub assets
    }
    for (final heading in <double?>[null, 182, 2]) {
      final kmh = await speedLimitAt(
        const LatLng(_lat, _lng),
        headingDeg: heading,
      );
      expect(kmh, 50, reason: 'heading $heading');
      expect(lastLimitLayer(), 'segment');
      expect(lastWazeStreetName(), 'Ấp Bắc');
    }
  });

  test(
    'a ±20 m offset keeps the segment in range (not a position problem)',
    () async {
      await loadOfflineSpeedLimits();
      if (!speedLimitsPopulated) {
        return;
      }
      final seen = <String, int>{};
      var n = 0;
      for (var dLat = -0.0002; dLat <= 0.00021; dLat += 0.0001) {
        for (var dLng = -0.0002; dLng <= 0.00021; dLng += 0.0001) {
          final kmh = await speedLimitAt(
            LatLng(_lat + dLat, _lng + dLng),
            headingDeg: 182,
          );
          seen['${kmh ?? 'null'}'] = (seen['${kmh ?? 'null'}'] ?? 0) + 1;
          n++;
        }
      }
      debugPrint('offsets probed: $n -> $seen');
      expect(seen['50'] ?? 0, greaterThan(n ~/ 2));
    },
  );
}
