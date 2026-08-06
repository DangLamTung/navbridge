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
}
