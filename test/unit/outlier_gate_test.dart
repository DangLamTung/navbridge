/// Unit tests for the GPS outlier gate (`outlier_gate.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/outlier_gate.dart';

const mPerLng = 111320.0 * 0.9822; // meters per degree lng at lat 10.82

void main() {
  group('OutlierGate', () {

    test('8 cases', () {
    // ---- case: accepts normal fixes and learns the smoothed speed ----
    (() {
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

    })();


    // ---- case: rejects a single 40 m / 1 s jump inconsistent with speed ----
    (() {
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

    })();


    // ---- case: accepts a large movement over a real GPS gap (dt large) ----
    (() {
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

    })();


    // ---- case: rejects a fix with accuracy > 35 m (from the 2nd fix on) ----
    (() {
        final g = OutlierGate();
        // The FIRST fix is exempt while the receiver warms up (see
        // _coldStartAccuracyM) — the ceiling applies from the second fix on.
        expect(
          g.accept(const LatLng(10.82, 106.62), accuracy: 20, dt: null),
          isTrue,
        );
        expect(
          g.accept(LatLng(10.82, 106.62 + 5.0 / mPerLng),
              accuracy: 50, dt: 1.0),
          isFalse,
        );
        expect(g.rejected, 1);

    })();


    // ---- case: a rejected jump does not corrupt the smoothed speed ----
    (() {
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

    })();


    // ---- case: a drive that starts ALREADY MOVING is not rejected forever ----
    (() {
        // Measured on the long-trip replay (2026-09-27): with the prior at 0 the
        // jump floor is 5 m/s × 0.94 s × 3 = 14 m, so a car doing 76 km/h (20 m
        // per fix) was rejected — and since the EMA only moves on ACCEPTED fixes
        // it stayed 0, so every later fix was rejected too: dt ran away
        // 0.94 → 1.88 → 2.82 s … and the dial showed nothing for the whole run.
        final g = OutlierGate();
        final step = 20.0 / mPerLng; // 20 m per fix, 0.94 s apart = 76 km/h
        expect(g.accept(const LatLng(10.82, 106.62), dt: null, speedMps: 21.3),
            isTrue);
        for (var i = 1; i <= 5; i++) {
          expect(
            g.accept(
              LatLng(10.82, 106.62 + i * step),
              dt: 0.94,
              speedMps: 21.3,
            ),
            isTrue,
            reason: 'fix $i was rejected — the gate is deadlocked on a cold start',
          );
        }
        expect(g.rejected, 0);

    })();


    // ---- case: the cold-start seed does not defeat the burst gate ----
    (() {
        // The seed is used ONCE. A 449 km/h burst after a normal fix is still
        // rejected even though the fix reports a nonsense speed of its own.
        final g = OutlierGate();
        g.accept(const LatLng(10.82, 106.62), dt: null, speedMps: 20);
        expect(
          g.accept(LatLng(10.82, 106.62 + 20.0 / mPerLng), dt: 1.0, speedMps: 20),
          isTrue,
        );
        expect(
          g.accept(LatLng(10.82, 106.62 + 145.0 / mPerLng),
              dt: 1.0, speedMps: 125),
          isFalse,
        );

    })();


    // ---- case: the FIRST fix may be coarse (cold start) ----
    (() {
        // A cold start hands out the fused provider's network/wifi fix first —
        // often 50-500 m — while the satellite fix is still locking. Rejecting
        // it left the map blank until GPS locked, and threw away every fix
        // `_seedGpsFix()` produced (user, 2026-10-08: "start is slow to catch
        // gps"). Only the FIRST fix gets the wide ceiling.
        final g = OutlierGate();
        expect(
          g.accept(const LatLng(10.82, 106.62), dt: null, accuracy: 300),
          isTrue,
          reason: 'the first fix has no previous position to be inconsistent with',
        );
        // From the 2nd fix the normal 35 m ceiling is back.
        expect(
          g.accept(LatLng(10.82, 106.62 + 10.0 / mPerLng), dt: 1.0, accuracy: 300),
          isFalse,
        );
        expect(g.lastReason, 'accuracy');
        // And an absurd cell-only fix is still refused, even first.
        final g2 = OutlierGate();
        expect(
          g2.accept(const LatLng(10.82, 106.62), dt: null, accuracy: 1500),
          isFalse,
        );

    })();
    });

  });
}
