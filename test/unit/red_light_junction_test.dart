import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/sign_limit.dart';

void main() {
  group('redLightCameraCoversJunction', () {
    test('same junction within 150 m → the light callout is suppressed', () {
      expect(
        redLightCameraCoversJunction(
          signMeters: 90,
          cameraMeters: 120,
          isRedLightCamera: true,
        ),
        isTrue,
      );
      expect(
        redLightCameraCoversJunction(
          signMeters: 90,
          cameraMeters: 240,
          isRedLightCamera: true,
        ),
        isTrue,
      );
    });

    test('a different junction is not suppressed', () {
      expect(
        redLightCameraCoversJunction(
          signMeters: 90,
          cameraMeters: 241,
          isRedLightCamera: true,
        ),
        isFalse,
      );
    });

    test('no camera / a non-red-light camera keeps the light callout', () {
      expect(
        redLightCameraCoversJunction(
          signMeters: 90,
          cameraMeters: null,
          isRedLightCamera: true,
        ),
        isFalse,
      );
      expect(
        redLightCameraCoversJunction(
          signMeters: 90,
          cameraMeters: 90,
          isRedLightCamera: false,
        ),
        isFalse,
      );
    });

    test('the tolerance is configurable', () {
      expect(
        redLightCameraCoversJunction(
          signMeters: 0,
          cameraMeters: 100,
          isRedLightCamera: true,
          toleranceM: 50,
        ),
        isFalse,
      );
    });
  });
}
