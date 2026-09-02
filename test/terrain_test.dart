/// Tests for the offline DEM module (`terrain.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show lonToTileX, latToTileY;
import 'package:navbridge/services/terrain.dart';

void main() {
  group('terrariumDecode', () {
    test('decodes Terrarium RGB to elevation in meters', () {
      // Sea level: r=128, g=0 → 128*256 − 32768 = 0.
      expect(terrariumDecode(128, 0, 0), closeTo(0, 0.01));
      // +1000 m → 33768 = 131*256 + 232.
      expect(terrariumDecode(131, 232, 0), closeTo(1000, 0.01));
      // −100 m → 32668 = 127*256 + 156.
      expect(terrariumDecode(127, 156, 0), closeTo(-100, 0.01));
      // Sub-meter via blue channel: +0.5 m → 32768.5 → r=128,g=0,b=128.
      expect(terrariumDecode(128, 0, 128), closeTo(0.5, 0.01));
    });
  });

  group('applyTerrainToStyle', () {
    final base = <String, dynamic>{
      'version': 8,
      'sources': {
        'openmaptiles': {'type': 'vector'},
      },
      'layers': <dynamic>[],
    };
    final dem = <String, dynamic>{
      'type': 'raster-dem',
      'tiles': ['file:///terrain/{z}/{x}/{y}.png'],
      'encoding': 'terrarium',
    };

    test('injects terrain when enabled and DEM present', () {
      final style = applyTerrainToStyle(base, dem, enabled: true);
      final src = style['sources'] as Map<String, dynamic>;
      expect(src['terrain-dem'], same(dem));
      final layers = style['layers'] as List<dynamic>;
      final hs =
          layers.firstWhere((l) => l is Map && l['id'] == 'terrain-hillshade')
              as Map<String, dynamic>;
      expect(hs['type'], 'hillshade');
      expect(hs['source'], 'terrain-dem');
      final paint = hs['paint'] as Map<String, dynamic>;
      // Default exaggeration 1.5 is boosted ×1.6 for visibility.
      expect(paint['hillshade-exaggeration'], closeTo(2.4, 0.001));
    });

    test('omits terrain when disabled', () {
      final style = applyTerrainToStyle(base, dem, enabled: false);
      final layers = style['layers'] as List<dynamic>;
      expect(
        layers.any((l) => l is Map && l['id'] == 'terrain-hillshade'),
        isFalse,
      );
      expect(
        (style['sources'] as Map<String, dynamic>).containsKey('terrain-dem'),
        isFalse,
      );
    });

    test('omits terrain when no DEM data', () {
      final style = applyTerrainToStyle(base, null, enabled: true);
      final layers = style['layers'] as List<dynamic>;
      expect(
        layers.any((l) => l is Map && l['id'] == 'terrain-hillshade'),
        isFalse,
      );
      expect(
        (style['sources'] as Map<String, dynamic>).containsKey('terrain-dem'),
        isFalse,
      );
    });

    test('does not mutate the base style', () {
      applyTerrainToStyle(base, dem, enabled: true);
      final baseLayers = base['layers'] as List<dynamic>;
      expect(
        baseLayers.any((l) => l is Map && l['id'] == 'terrain-hillshade'),
        isFalse,
      );
      expect(
        (base['sources'] as Map<String, dynamic>).containsKey('terrain-dem'),
        isFalse,
      );
    });
  });

  group('TerrainDownloader', () {
    test('counts tiles equal to the per-zoom sum over the zoom range', () {
      final b = LatLngBounds(
        const LatLng(10.70, 106.60),
        const LatLng(10.85, 106.80),
      );
      final dl = TerrainDownloader(b);
      var expected = 0;
      for (var z = kTerrainMinZoom; z <= kTerrainMaxZoom; z++) {
        final x0 = lonToTileX(b.west, z);
        final x1 = lonToTileX(b.east, z);
        final y0 = latToTileY(b.north, z);
        final y1 = latToTileY(b.south, z);
        expected += (x1 - x0 + 1) * (y1 - y0 + 1);
      }
      expect(dl.total, expected);
      expect(dl.total, greaterThan(0));
    });
  });
}
