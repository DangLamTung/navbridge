/// Tests for the complementary car filter (`car_filter.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/car_filter.dart';

const mPerLng = 111320.0 * 0.9822; // meters per degree lng at lat 10.82°

void main() {
  group('CarFilter', () {
    test('starts at the first fix', () {
      final f = CarFilter();
      final p = const LatLng(10.82, 106.62);
      f.update(p, routeBearing: 90);
      expect(f.position.latitude, closeTo(p.latitude, 1e-6));
      expect(f.position.longitude, closeTo(p.longitude, 1e-6));
      expect(f.speedMps, 0);
      expect(f.initialized, isTrue);
    });

    test('smoothes the speed estimate from consecutive fixes', () {
      final f = CarFilter();
      f.update(const LatLng(10.82, 106.62), routeBearing: 90);
      for (var i = 1; i <= 5; i++) {
        final lng = 106.62 + (i * 10.0) / mPerLng;
        f.update(LatLng(10.82, lng), dt: 1.0, routeBearing: 90);
      }
      // Converges toward ~10 m/s (low-pass alpha 0.3, after 5 fixes the
      // steady-state error is small).
      expect(f.speedMps, greaterThan(5));
      expect(f.speedMps, lessThan(15));
      // Heading follows the route bearing (east = 90°).
      expect(f.bearing, closeTo(90, 5));
    });

    test('dead-reckons forward along the route bearing between fixes', () {
      final f = CarFilter();
      f.update(const LatLng(10.82, 106.62), routeBearing: 90);
      for (var i = 1; i <= 5; i++) {
        final lng = 106.62 + (i * 10.0) / mPerLng;
        f.update(LatLng(10.82, lng), dt: 1.0, routeBearing: 90);
      }
      final before = f.position;
      final after = f.predict(0.5); // 0.5 s of dead-reckoning
      final moved = (after.longitude - before.longitude) * mPerLng;
      // ~10 m/s × 0.5 s ≈ 5 m east.
      expect(moved, closeTo(5.0, 3.0));
    });

    test('a single GPS outlier barely disturbs position or speed', () {
      final f = CarFilter();
      f.update(const LatLng(10.82, 106.62), routeBearing: 90);
      for (var i = 1; i <= 3; i++) {
        final lng = 106.62 + (i * 10.0) / mPerLng;
        f.update(LatLng(10.82, lng), dt: 1.0, routeBearing: 90);
      }
      // One 40 m jump (outlier), then the next fix is back on track.
      f.update(
        LatLng(10.82, 106.62 + (4 * 10.0 + 40) / mPerLng),
        dt: 1.0,
        routeBearing: 90,
      );
      f.update(
        LatLng(10.82, 106.62 + (5 * 10.0) / mPerLng),
        dt: 1.0,
        routeBearing: 90,
      );
      // Speed must not explode toward 50 m/s.
      expect(f.speedMps, lessThan(30));
      // Position is heavily pulled toward the on-route fix (alpha 0.8), so it
      // stays close to the true track.
      final trueLng = 106.62 + (5 * 10.0) / mPerLng;
      final err = (f.position.longitude - trueLng).abs() * mPerLng;
      expect(err, lessThan(20));
    });

    test('falls back to the travel bearing when no route bearing is given', () {
      final f = CarFilter();
      f.update(const LatLng(10.82, 106.62));
      for (var i = 1; i <= 6; i++) {
        final lng = 106.62 + (i * 10.0) / mPerLng;
        f.update(LatLng(10.82, lng), dt: 1.0); // no routeBearing
      }
      // Moving east → bearing converges toward ≈ 90° (low-pass, ~87° after
      // 6 fixes).
      expect(f.bearing, closeTo(90, 15));
    });
  });
}
