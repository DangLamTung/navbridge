// PROBE (temporary): why does the layer answer 60 offline but the app shows '-'?
// Calls the app's own lookup at the QL1A point with the exact parameter
// combinations the page can pass, so the difference is isolated, not guessed.
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probe', () async {
    await loadOfflineSpeedLimits();
    // Quang Ngai stretch of the QL1A fixture (pack says 60 within a couple of
    // metres; the web run showed '-' here).
    const p = LatLng(15.4271, 108.6641);
    // The trip drives south, so the recorded heading is ~170-190.
    for (final heading in [null, 76.0, 170.0, 180.0]) {
      for (final keep in [null, 0, 50, 60]) {
        for (final street in [null, '', 'QL1']) {
          final r = await lookupSpeedLimit(
            p,
            headingDeg: heading,
            keepKmh: keep,
            expectStreet: street,
          );
          // ignore: avoid_print
          print(
            'heading=${heading ?? '-'} keep=${keep ?? '-'} expect="${street ?? '-'}"'
            ' → ${r == null ? 'NULL' : '${r.limit} via ${r.source} street="${r.streetName}" seg=${r.segmentId}'}',
          );
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
