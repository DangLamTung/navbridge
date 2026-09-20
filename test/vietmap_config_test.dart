/// Security regression: no Vietmap API keys may be compiled into the app.
///
/// The real keys were committed to a public repo once and had to be rotated.
/// Keys must only come from `--dart-define` at build time; without them the
/// constants are empty and [VietmapConfig.hasKeys] is false.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/vietmap_config.dart';

void main() {
  test('no Vietmap keys are compiled in by default', () {
    expect(VietmapConfig.apiKey, isEmpty);
    expect(VietmapConfig.tileKey, isEmpty);
    expect(VietmapConfig.hasKeys, isFalse);
  });

  group('VietmapConfig key round-robin and quarantine', () {
    setUp(() {
      VietmapConfig.resetQuarantineForTesting();
    });

    tearDown(() {
      VietmapConfig.setKeysForTesting(null);
    });

    test('round-robins across active keys', () {
      VietmapConfig.setKeysForTesting(['key1', 'key2', 'key3']);
      expect(VietmapConfig.nextKey(), 'key1');
      expect(VietmapConfig.nextKey(), 'key2');
      expect(VietmapConfig.nextKey(), 'key3');
      expect(VietmapConfig.nextKey(), 'key1');
    });

    test('quarantined key is skipped during round-robin', () {
      VietmapConfig.setKeysForTesting(['keyA', 'keyB', 'keyC']);
      VietmapConfig.markKeyFailed('keyB');

      expect(VietmapConfig.isKeyQuarantined('keyB'), isTrue);
      expect(VietmapConfig.isKeyQuarantined('keyA'), isFalse);

      // Should skip keyB and alternate keyA and keyC
      expect(VietmapConfig.nextKey(), 'keyA');
      expect(VietmapConfig.nextKey(), 'keyC');
      expect(VietmapConfig.nextKey(), 'keyA');
      expect(VietmapConfig.nextKey(), 'keyC');
    });

    test('falls back to round-robin when all keys are quarantined', () {
      VietmapConfig.setKeysForTesting(['keyX', 'keyY']);
      VietmapConfig.markKeyFailed('keyX');
      VietmapConfig.markKeyFailed('keyY');

      // Both quarantined: fallback to regular round-robin so search is still attempted
      expect(VietmapConfig.nextKey(), 'keyX');
      expect(VietmapConfig.nextKey(), 'keyY');
    });
  });
}
