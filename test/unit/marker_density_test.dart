/// Marker density must rise with zoom and never escape its ceiling — an
/// unbounded sign/camera layer is what makes the low-end phone stutter, since
/// every marker is reprojected on the camera ticker.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/ui/marker_density.dart';

void main() {
  test('signs: none at region scale, more as you zoom in, capped', () {
    expect(signMarkerCap(9), 20); // floor: 11 is the "show nothing" cut-off
    expect(signMarkerCap(13), 20);
    expect(signMarkerCap(15), greaterThan(signMarkerCap(13)));
    expect(signMarkerCap(17), kMaxSignMarkers);
    expect(signMarkerCap(19), kMaxSignMarkers); // never above the ceiling
    expect(signMarkerCap(22), kMaxSignMarkers);
  });

  test(
    'street level keeps a useful budget (the "signs are missing" complaint)',
    () {
      // The cap is applied AFTER picking the signs nearest the car, so a big
      // number here is a window around the driver, not a whole-route budget.
      // 60 (the old ceiling) read as "too little" on a long route.
      expect(signMarkerCap(17), greaterThanOrEqualTo(100));
      expect(cameraMarkerCap(17), greaterThanOrEqualTo(60));
    },
  );

  test('cameras: same shape, slightly smaller floor', () {
    expect(cameraMarkerCap(13), 12);
    expect(cameraMarkerCap(15), greaterThan(cameraMarkerCap(13)));
    expect(cameraMarkerCap(17), kMaxCameraMarkers);
    expect(cameraMarkerCap(19), kMaxCameraMarkers);
  });

  test('PiP asks for a handful, not the street-level curve', () {
    // The PiP map sits at a fixed z13 inside a window a few centimetres wide,
    // with the speed bar above and the maneuver bar below. The curve would put
    // 20 signs + 12 cameras in there, which buries the road itself — reported
    // 2026-10-15 as "too dense information to the point can not see the path".
    expect(signMarkerCap(13), 20);
    expect(cameraMarkerCap(13), 12);
    expect(kPipSignMarkers, lessThan(signMarkerCap(13)));
    expect(kPipCameraMarkers, lessThan(cameraMarkerCap(13)));
    // "About 5" per the request: a few either way is fine, a dozen is not.
    expect(kPipSignMarkers, inInclusiveRange(3, 8));
    expect(kPipCameraMarkers, inInclusiveRange(3, 8));
  });

  test('density never decreases as the camera zooms in', () {
    var prev = -1;
    for (var z = 10.0; z <= 19.0; z += 0.25) {
      final n = signMarkerCap(z);
      expect(n, greaterThanOrEqualTo(prev), reason: 'zoom $z went backwards');
      expect(n, lessThanOrEqualTo(kMaxSignMarkers));
      prev = n;
    }
  });

  test('the hard cap survives raising the zoom ceiling', () {
    // atMax may be tuned later; hardCap is the contract with the device.
    expect(
      markerCapForZoom(
        30,
        atMin: 5,
        atMax: 500,
        minZoom: 10,
        maxZoom: 20,
        hardCap: 42,
      ),
      42,
    );
  });

  test('NaN / silly zooms do not produce a huge layer', () {
    expect(markerCapForZoom(double.nan, atMin: 8, atMax: 60), 8);
    expect(markerCapForZoom(-5, atMin: 8, atMax: 60), 8);
  });
}
