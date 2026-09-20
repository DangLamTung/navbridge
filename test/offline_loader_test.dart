/// Tests for the shared offline data readers (`offline_loader.dart`).
///
/// These are the ONE place that decides "downloaded copy beats bundled asset".
/// Before they existed the decision was copy-pasted per loader (cameras, signs)
/// and missing entirely for the posted speed-limit layer.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('readOfflineText', () {
    test(
      'falls back to the bundled asset when nothing was downloaded',
      () async {
        // Unit tests have no app-support dir (path_provider has no plugin here),
        // which is exactly the "no downloaded copy" path. `manifest.json` is
        // small and tracked, so this runs on CI and locally alike.
        final raw = await readOfflineText('manifest.json');
        expect(raw, isNotEmpty);
        expect(raw.trimLeft().startsWith('{'), isTrue);
      },
    );

    test('returns what a plain bundle load returns', () async {
      final viaHelper = await readOfflineText('manifest.json');
      final direct = await rootBundle.loadString(
        'assets/offline_map/manifest.json',
      );
      expect(viaHelper, direct);
    });

    test('throws for an asset that does not exist, so callers can degrade', () {
      expect(readOfflineText('definitely_not_here.json'), throwsA(anything));
    });
  });

  group('readOfflineBytes', () {
    test(
      'reads a bundled binary pack without slicing the buffer by hand',
      () async {
        final bytes = await readOfflineBytes('signs/no_u_turn.png');
        expect(bytes, isNotEmpty);
      },
    );

    test('throws for a missing pack, so callers can degrade', () {
      expect(readOfflineBytes('definitely_not_here.bin'), throwsA(anything));
    });
  });
}
