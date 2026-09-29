/// The offline download links the Offline screen shows (see `offline_links.dart`).
///
/// The point of this file: a release build used to carry no offline download
/// URLs at all (they came only from `--dart-define`), so the driver could not
/// see or open where the data comes from. These tests pin that every offline
/// source is listed and that the GraphHopper link always resolves to a real,
/// openable default.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_links.dart';
import 'package:navbridge/services/offline_router.dart'
    show graphDefaultUrl, resolveGraphUrl;

void main() {
  group('resolveGraphUrl', () {
    test('falls back to the built-in default when nothing is configured', () {
      // No GRAPH_URL in a plain `flutter test`, so all three agree.
      expect(resolveGraphUrl(), graphDefaultUrl);
      expect(resolveGraphUrl(''), graphDefaultUrl);
      expect(resolveGraphUrl(null), graphDefaultUrl);
      expect(graphDefaultUrl, startsWith('https://'));
      expect(graphDefaultUrl, contains('vietnam'));
    });

    test('a custom URL wins verbatim', () {
      const u = 'https://example.com/my-graph.ghz';
      expect(resolveGraphUrl(u), u);
    });
  });

  group('offlineDownloadLinks', () {
    test('lists every offline source, GraphHopper first and openable', () {
      final links = offlineDownloadLinks();
      expect(links.length, greaterThanOrEqualTo(5));
      expect(links.first.title, contains('GraphHopper'));
      // The GraphHopper link always resolves to a real, openable URL — this is
      // the link the request asked to be in the app.
      expect(links.first.url, graphDefaultUrl);
      expect(links.first.openable, isTrue);
      // Every kind of offline source is represented exactly once.
      for (final needle in [
        'GraphHopper',
        'PMTiles',
        'Camera',
        'Địa hình',
        'Nền bản đồ',
      ]) {
        expect(
          links.where((l) => l.title.contains(needle)).length,
          1,
          reason: 'missing/duplicated link for "$needle"',
        );
      }
    });

    test('tile templates are copyable but not openable', () {
      final terrain = offlineDownloadLinks().firstWhere(
        (l) => l.url.contains('terrarium'),
      );
      expect(terrain.template, isTrue);
      expect(terrain.openable, isFalse);
      expect(terrain.url, contains('{z}'));
    });

    test('self-hosted sources are flagged unconfigured without a build URL', () {
      final links = offlineDownloadLinks();
      // Tests run with no --dart-define, so the self-hosted sources have no URL.
      final nav = links.firstWhere((l) => l.title.contains('PMTiles'));
      expect(nav.configured, isFalse);
      expect(nav.openable, isFalse);
      final data = links.firstWhere((l) => l.title.contains('Camera'));
      expect(data.configured, isFalse);
      expect(data.openable, isFalse);
    });
  });
}
