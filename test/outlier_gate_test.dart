/// Unit tests for the GPS outlier gate (`outlier_gate.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/outlier_gate.dart';

const mPerLng = 111320.0 * 0.9822; // meters per degree lng at lat 10.82

void main() {
  group('OutlierGate', () {
    test('accepts normal fixes and learns the smoothed speed', () {
      final g = OutlierGate();
      expect(g.accept(const LatLng(10.82, 106.62), dt: null), isTrue);
      for (var i = 1; i <= 5; i++) {
        expect(
          g.accept(LatLng(10.82, 106.62 + (i * 10.0) / mPerLng), dt: 1.0),
          isTrue,
        );
      }
      // Converges toward ~10 m/s (alpha 0.5, after 5 fixes).
      expect(g.smoothSpeedMps, greaterThan(5));
      expect(g.smoothSpeedMps, lessThan(15));
      expect(g.rejected, 0);
    });

    test('rejects a single 40 m / 1 s jump inconsistent with speed', () {
      final g = OutlierGate();
      g.accept(const LatLng(10.82, 106.62), dt: null);
      for (var i = 1; i <= 3; i++) {
        g.accept(LatLng(10.82, 106.62 + (i * 10.0) / mPerLng), dt: 1.0);
      }
      // 40 m in 1 s = 144 km/h while the filter only knows ~10 m/s → reject.
      final ok = g.accept(
        LatLng(10.82, 106.62 + (4 * 10.0 + 40) / mPerLng),
        dt: 1.0,
      );
      expect(ok, isFalse);
      expect(g.rejected, 1);
    });

    test('accepts a large movement over a real GPS gap (dt large)', () {
      final g = OutlierGate();
      g.accept(const LatLng(10.82, 106.62), dt: null);
      for (var i = 1; i <= 3; i++) {
        g.accept(LatLng(10.82, 106.62 + (i * 10.0) / mPerLng), dt: 1.0);
      }
      // 90 m over an 8 s gap ≈ 40 km/h — a genuine GPS drop, must be kept.
      final ok = g.accept(
        LatLng(10.82, 106.62 + (3 * 10.0 + 90) / mPerLng),
        dt: 8.0,
      );
      expect(ok, isTrue);
    });

    test('rejects a fix with accuracy > 35 m', () {
      final g = OutlierGate();
      expect(
        g.accept(const LatLng(10.82, 106.62), accuracy: 50, dt: null),
        isFalse,
      );
      expect(g.rejected, 1);
    });

    test('a rejected jump does not corrupt the smoothed speed', () {
      final g = OutlierGate();
      g.accept(const LatLng(10.82, 106.62), dt: null);
      for (var i = 1; i <= 3; i++) {
        g.accept(LatLng(10.82, 106.62 + (i * 10.0) / mPerLng), dt: 1.0);
      }
      final before = g.smoothSpeedMps;
      g.accept(
        LatLng(10.82, 106.62 + (3 * 10.0 + 80) / mPerLng),
        dt: 1.0,
      ); // rejected
      expect(g.smoothSpeedMps, closeTo(before, 1e-9));
    });
  });
}
