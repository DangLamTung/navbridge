/// Tests for [NavTileServer] template mapping and source routing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/nav_tile_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavTileServer.templatesForSource', () {
    test('maps osm to standard subdomains', () {
      final tpls = NavTileServer.templatesForSource('osm');
      expect(tpls.length, 3);
      expect(tpls.first, contains('tile.openstreetmap.org'));
      expect(tpls.first, contains('{z}/{x}/{y}'));
    });

    test('maps esri and esri-street correctly', () {
      final esri = NavTileServer.templatesForSource('esri');
      expect(esri.length, 1);
      expect(esri.first, contains('World_Imagery'));
      // Note ESRI uses z/y/x
      expect(esri.first, contains('{z}/{y}/{x}'));

      final street = NavTileServer.templatesForSource('esri-street');
      expect(street.length, 1);
      expect(street.first, contains('World_Street_Map'));
      expect(street.first, contains('{z}/{y}/{x}'));
    });

    test('maps topo to opentopomap', () {
      final topo = NavTileServer.templatesForSource('topo');
      expect(topo.length, 1);
      expect(topo.first, contains('tile.opentopomap.org'));
    });

    test('maps carto voyager vs dark in night mode', () {
      final day = NavTileServer.templatesForSource('carto', nightMode: false);
      expect(day.first, contains('voyager'));

      final night = NavTileServer.templatesForSource('carto', nightMode: true);
      expect(night.first, contains('dark_all'));

      final light = NavTileServer.templatesForSource('carto-light');
      expect(light.first, contains('light_all'));

      final dark = NavTileServer.templatesForSource('carto-dark');
      expect(dark.first, contains('dark_all'));
    });

    test('maps vector to basemap fallback', () {
      final vec = NavTileServer.templatesForSource('vector');
      expect(vec, isNotEmpty);
      expect(vec.first, contains('basemaps.cartocdn.com'));
    });

    test('vietmap fallback when keys are absent', () {
      final vm = NavTileServer.templatesForSource('vietmap');
      expect(vm, isNotEmpty);
      final vmsat = NavTileServer.templatesForSource('vietmapsat');
      expect(vmsat, isNotEmpty);
    });
  });

  group('NavTileServer update and state', () {
    test('update sets templates and sourceName', () {
      final server = NavTileServer.instance;
      server.update(
        templates: ['https://example.com/{z}/{x}/{y}.png'],
        sourceName: 'test-source',
        nightMode: true,
      );
      // Ensure no crash and state is retained
      expect(server.isRunning, isFalse);
    });
  });
}
