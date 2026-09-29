/// Tests for [NavTileServer] template mapping and source routing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/nav_tile_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavTileServer.templatesForSource', () {




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
  });
}
