/// Tests for the offline-screen helpers (`offline_screen.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/offline_screen.dart';

void main() {
  group('formatBytes', () {
    test('bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(500), '500 B');
    });

    test('kilobytes', () {
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(2048), '2 KB');
    });

    test('megabytes', () {
      expect(formatBytes(5 * (1 << 20)), '5.0 MB');
    });

    test('gigabytes', () {
      expect(formatBytes(3 * (1 << 30)), '3.00 GB');
    });
  });
}
