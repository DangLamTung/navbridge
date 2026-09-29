import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/ui/nav_layout_math.dart';

/// The bearing glide (wrap-around, no overshoot) and the "park the sign beside
/// the road" marker fan — cheap to get wrong, invisible in a screenshot.
void main() {
  group('easeBearingDeg', () {

    test('6 cases', () {
    // ---- case: first step moves a fraction of the way toward the target ----
    (() {
        final b = easeBearingDeg(0, 90, 1 / 30);
        expect(b, greaterThan(0));
        expect(b, lessThan(90));
        // tau 0.25 s at 30 fps → ~12.5 % of the error in the first frame.
        expect(b, closeTo(11.3, 1.0));

    })();


    // ---- case: converges to the target within ~1 s of frames ----
    (() {
        var b = 0.0;
        for (var i = 0; i < 30; i++) {
          b = easeBearingDeg(b, 90, 1 / 30);
        }
        // exp(-1/0.25) = 1.8 % of the 90° error left after 1 s.
        expect(b, closeTo(90, 2.0));

    })();


    // ---- case: crosses 0 the short way (350 -> 10 goes forward, not backward) ----
    (() {
        final b = easeBearingDeg(350, 10, 1 / 30);
        expect(b, greaterThan(350)); // forward through 360/0
        expect(b, lessThan(360));
        expect(easeBearingDeg(350, 10, 0.5), closeTo(6.8, 2.0));

    })();


    // ---- case: crosses 0 the short way downward too (10 -> 350) ----
    (() {
        final b = easeBearingDeg(10, 350, 1 / 30);
        expect(b, lessThan(10));
        expect(b, greaterThan(0));

    })();


    // ---- case: never overshoots past the target ----
    (() {
        var b = 0.0;
        for (var i = 0; i < 200; i++) {
          b = easeBearingDeg(b, 45, 1 / 30);
          expect(b, lessThanOrEqualTo(45.0001));
        }

    })();


    // ---- case: a wild dt snaps instead of gliding ----
    (() {
        expect(easeBearingDeg(0, 90, 0), 90);
        expect(easeBearingDeg(0, 90, 5), 90);

    })();
    });

  });

  group('rightOfTravel', () {

    test('5 cases', () {
    // ---- case: heading-up: right of travel is screen-right ----
    (() {
        final v = rightOfTravel(roadBearingDeg: 137, cameraBearingDeg: 137);
        expect(v.dx, closeTo(1.0, 1e-9));
        expect(v.dy, closeTo(0.0, 1e-9));

    })();


    // ---- case: north-up: right of a northbound road is screen-right (east) ----
    (() {
        final v = rightOfTravel(roadBearingDeg: 0, cameraBearingDeg: 0);
        expect(v.dx, closeTo(1.0, 1e-9));
        expect(v.dy, closeTo(0.0, 1e-9));

    })();


    // ---- case: north-up: right of an eastbound road points down-screen (south) ----
    (() {
        final v = rightOfTravel(roadBearingDeg: 90, cameraBearingDeg: 0);
        expect(v.dx, closeTo(0.0, 1e-9));
        expect(v.dy, closeTo(1.0, 1e-9));

    })();


    // ---- case: turned camera: the offset follows the map rotation ----
    (() {
        // Map rotated 90° (the camera faces east); the car still drives east, so
        // the right shoulder is still screen-right.
        final v = rightOfTravel(roadBearingDeg: 90, cameraBearingDeg: 90);
        expect(v.dx, closeTo(1.0, 1e-9));
        expect(v.dy, closeTo(0.0, 1e-9));

    })();


    // ---- case: unknown road bearing falls back to screen-right ----
    (() {
        for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
          final v = rightOfTravel(roadBearingDeg: bad, cameraBearingDeg: 42);
          expect(v, const Offset(1, 0));
        }

    })();
    });

  });

  group('spreadSignMarkers', () {
    const headingUp = 137.0;


    test('7 cases', () {
    // ---- case: a lone sign is parked beside the road, not on it ----
    (() {
        final out = spreadSignMarkers(
          const [Offset(400, 300)],
          roadBearingDeg: headingUp,
          cameraBearingDeg: headingUp,
          sidePx: 24,
        );
        expect(out.single, const Offset(424, 300));
        expect((out.single - const Offset(400, 300)).distance, closeTo(24, 1e-9));

    })();


    // ---- case: two signs at one junction straddle the road ----
    (() {
        final out = spreadSignMarkers(
          const [Offset(400, 300), Offset(402, 301)],
          roadBearingDeg: headingUp,
          cameraBearingDeg: headingUp,
        );
        expect(out[0].dx, closeTo(424, 1e-9)); // right shoulder
        expect(out[1].dx, closeTo(378, 1e-9)); // left shoulder
        expect((out[0] - out[1]).distance, greaterThanOrEqualTo(44.0));

    })();


    // ---- case: three signs at one junction are fanned out, none overlapping ----
    (() {
        final out = spreadSignMarkers(
          const [Offset(400, 300), Offset(402, 301), Offset(399, 302)],
          roadBearingDeg: headingUp,
          cameraBearingDeg: headingUp,
        );
        expect(out.length, 3);
        for (var i = 0; i < out.length; i++) {
          for (var j = i + 1; j < out.length; j++) {
            expect(
              (out[i] - out[j]).distance,
              greaterThanOrEqualTo(44.0),
              reason: 'markers $i and $j still overlap',
            );
          }
        }
        // Right 24, left 24, then the next right slot (24 + 56).
        expect(out[0].dx, closeTo(424, 1e-9));
        expect(out[1].dx, closeTo(378, 1e-9));
        expect(out[2].dx, closeTo(479, 1e-9));
        for (final o in out) {
          expect(o.dy, closeTo(301, 1.5));
        }

    })();


    // ---- case: signs far apart keep the plain side offset (no needless push) ----
    (() {
        final out = spreadSignMarkers(
          const [Offset(100, 100), Offset(400, 500), Offset(700, 900)],
          roadBearingDeg: headingUp,
          cameraBearingDeg: headingUp,
        );
        expect(out[0], const Offset(124, 100));
        expect(out[1], const Offset(424, 500));
        expect(out[2], const Offset(724, 900));

    })();


    // ---- case: order is preserved so overlays stay keyed to their sign ----
    (() {
        final pts = [Offset(10, 10), Offset(11, 11), Offset(900, 900)];
        final out = spreadSignMarkers(
          pts,
          roadBearingDeg: headingUp,
          cameraBearingDeg: headingUp,
        );
        expect(out.length, pts.length);
        expect(out[2].dx, closeTo(924, 1e-9));

    })();


    // ---- case: north-up: the fan runs across the road, not across the screen ----
    (() {
        // Eastbound road, north-up map: the shoulders are screen-up/down.
        final out = spreadSignMarkers(
          const [Offset(400, 300), Offset(401, 301)],
          roadBearingDeg: 90,
          cameraBearingDeg: 0,
        );
        expect(out[0].dx, closeTo(400, 1e-9));
        expect(out[0].dy, closeTo(324, 1e-9));
        expect(out[1].dy, closeTo(277, 1e-9));

    })();


    // ---- case: empty input is fine ----
    (() {
        expect(
          spreadSignMarkers(
            const [],
            roadBearingDeg: 90,
            cameraBearingDeg: 0,
          ),
          isEmpty,
        );

    })();
    });

  });
}
