/// Tests for [NavTileServer] template mapping and source routing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/nav_tile_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavTileServer.templatesForSource', () {
    test('the on-device source has no online templates of its own', () {
      expect(NavTileServer.templatesForSource('offline'), isEmpty);
      expect(NavTileServer.isOnDeviceSource('offline'), isTrue);
      expect(NavTileServer.isOnDeviceSource('vector'), isTrue);
      expect(NavTileServer.isOnDeviceSource('osm'), isFalse);
    });

    test('the emergency sources are real online rasters, OSM first', () {
      expect(NavTileServer.emergencySources.first, 'osm');
      for (final s in NavTileServer.emergencySources) {
        expect(
          NavTileServer.templatesForSource(s),
          isNotEmpty,
          reason: '$s must have templates to serve',
        );
      }
      final t = NavTileServer.templatesForSource(
        NavTileServer.emergencySources.first,
      );
      expect(t.first, contains('openstreetmap'));
    });

    test('CARTO is not an emergency source (its keyless tiles are blank)', () {
      expect(NavTileServer.emergencySources, isNot(contains('carto')));
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

  group('what a missing tile resolves to', () {
    test('an on-device layer goes ONLINE rather than drawing nothing', () {
      // The driver left the downloaded area while the layer is "offline": a
      // transparent tile here is the blank-map bug.
      expect(NavTileServer.resolvePlan('offline', online: true), [
        'offline',
        ...NavTileServer.emergencySources,
      ]);
      expect(NavTileServer.resolvePlan('vector', online: true), [
        'vector',
        ...NavTileServer.emergencySources,
      ]);
    });

    test('an online layer keeps its own (style-matched) mirrors', () {
      expect(NavTileServer.resolvePlan('osm', online: true), ['osm']);
      expect(NavTileServer.resolvePlan('esri', online: true), ['esri']);
    });

    test('with no connection nothing is fetched — disk only', () {
      expect(NavTileServer.resolvePlan('offline', online: false), ['offline']);
      expect(NavTileServer.resolvePlan('osm', online: false), ['osm']);
    });

    test('a request with no source name has nothing to fall back to', () {
      expect(NavTileServer.resolvePlan(null, online: true), isEmpty);
    });
  });

  group('NavTileServer update and state', () {});
}
