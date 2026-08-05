/// Tests for the slippy-map math and region sizing (`offline_tiles.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/offline_tiles.dart';

void main() {
  group('region download source', () {
    test('bulk download source is configured and is NOT OpenStreetMap', () {
      // tile.openstreetmap.org prohibits bulk/pre-downloading and has
      // IP-banned this app before — the downloader must never point at it.
      expect(
        tileDownloadBaseUrl,
        isNotEmpty,
        reason: 'the region downloader should be enabled',
      );
      expect(
        tileDownloadBaseUrl.toLowerCase(),
        isNot(contains('openstreetmap.org')),
      );
      expect(
        tileDownloadBaseUrl,
        contains('{z}/{x}/{y}'),
        reason: 'a z/x/y tile template must be configured',
      );
    });
  });

  group('slippy tile math', () {
    test('lonToTileX', () {
      expect(lonToTileX(-180, 1), 0);
      expect(lonToTileX(0, 1), 1);
      expect(lonToTileX(0, 2), 2);
    });

    test('latToTileY', () {
      expect(latToTileY(0, 1), 1);
      expect(latToTileY(85, 1), 0); // near the Mercator top
      expect(latToTileY(-85, 1), 1);
    });
  });

  group('OfflineRegion size', () {
    OfflineRegion singleTile() => OfflineRegion(
      name: 't',
      swLat: 0,
      swLon: 0,
      neLat: 0,
      neLon: 0,
      minZoom: 0,
      maxZoom: 0,
      downloadedAt: DateTime(2026),
    );

    test('a degenerate region is exactly one tile at z0', () {
      expect(singleTile().tileCount, 1);
    });

    test('tile count grows with zoom', () {
      final base = OfflineRegion(
        name: 't',
        swLat: 10.70,
        swLon: 106.60,
        neLat: 10.85,
        neLon: 106.80,
        minZoom: 13,
        maxZoom: 13,
        downloadedAt: DateTime(2026),
      );
      final bigger = OfflineRegion(
        name: 't',
        swLat: 10.70,
        swLon: 106.60,
        neLat: 10.85,
        neLon: 106.80,
        minZoom: 13,
        maxZoom: 14,
        downloadedAt: DateTime(2026),
      );
      expect(base.tileCount, greaterThan(0));
      expect(bigger.tileCount, greaterThan(base.tileCount));
    });

    test('estimatedBytes is positive', () {
      expect(singleTile().estimatedBytes, greaterThan(0));
    });
  });
}
