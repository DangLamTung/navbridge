/// The provider chain is the ONE place that decides routing order and what each
/// backend can honour. Both used to be implicit: the order lived in a chain of
/// `if`s inside `fetchAnyRoutes`, and nothing recorded that Vietmap silently
/// drops the "tránh cao tốc" toggle. These tests pin the behaviour the settings
/// screen now displays.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show forceOffline, routingEngine;
import 'package:navbridge/services/route_providers.dart';
import 'package:navbridge/services/vietmap_config.dart' show dataSource;

void main() {
  setUp(() {
    dataSource = 'osm';
    forceOffline = false;
    routingEngine = 'auto';
  });

  group('order', () {
    test(
      'default OSM source: car may use the offline graph, others go online',
      () {
        expect(resolveRouteChain(RouteProfile.car), [
          RouteProvider.graphhopper,
          RouteProvider.osrm,
        ]);
        // The on-device graph is car-only, so every other profile is online OSRM.
        for (final p in [
          RouteProfile.motorbike,
          RouteProfile.bicycle,
          RouteProfile.walking,
        ]) {
          expect(resolveRouteChain(p), [RouteProvider.osrm]);
        }
      },
    );

    test('Google source is tried first, then offline graph, then OSRM', () {
      dataSource = 'google';
      expect(resolveRouteChain(RouteProfile.car), [
        RouteProvider.google,
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
      // No offline graph for a motorbike → Google, then OSRM.
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.google,
        RouteProvider.osrm,
      ]);
    });

    test('Vietmap serves car/motorbike only, and still falls back to OSRM', () {
      dataSource = 'vietmap';
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.vietmap,
        RouteProvider.osrm,
      ]);
      expect(resolveRouteChain(RouteProfile.car), [
        RouteProvider.vietmap,
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
      // route v4 offers no bicycle/foot profile.
      expect(resolveRouteChain(RouteProfile.bicycle), [RouteProvider.osrm]);
    });

    test(
      'forceOffline drops every online provider, even the chosen source',
      () {
        forceOffline = true;
        expect(resolveRouteChain(RouteProfile.car), [
          RouteProvider.graphhopper,
        ]);
        expect(resolveRouteChain(RouteProfile.motorbike), isEmpty);
        dataSource = 'google';
        expect(resolveRouteChain(RouteProfile.car), [
          RouteProvider.graphhopper,
        ]);
        dataSource = 'vietmap';
        expect(resolveRouteChain(RouteProfile.car), [
          RouteProvider.graphhopper,
        ]);
      },
    );

    test('pinning the engine to graphhopper removes OSRM (and vice versa)', () {
      routingEngine = 'graphhopper';
      expect(resolveRouteChain(RouteProfile.car), [RouteProvider.graphhopper]);
      expect(resolveRouteChain(RouteProfile.motorbike), isEmpty);

      routingEngine = 'osrm';
      expect(resolveRouteChain(RouteProfile.car), [RouteProvider.osrm]);
    });

    test('describeRouteChain spells the order out for the UI', () {
      expect(describeRouteChain(RouteProfile.car), 'GraphHopper → OSRM');
      dataSource = 'google';
      expect(describeRouteChain(RouteProfile.motorbike), 'Google → OSRM');
      forceOffline = true;
      expect(
        describeRouteChain(RouteProfile.motorbike),
        'Không có nguồn nào cho loại xe này',
      );
    });
  });

  group('what each provider can honour', () {
    test('Google honours avoid for car/motorbike/bicycle, not walking', () {
      expect(RouteProvider.google.canAvoidHighway(RouteProfile.car), isTrue);
      expect(
        RouteProvider.google.canAvoidHighway(RouteProfile.motorbike),
        isTrue,
      );
      expect(
        RouteProvider.google.canAvoidHighway(RouteProfile.bicycle),
        isTrue,
      );
      // Walking has no highways and the Legacy API ignores `avoid` there.
      expect(
        RouteProvider.google.canAvoidHighway(RouteProfile.walking),
        isFalse,
      );
      expect(
        RouteProvider.google.canAvoidFerry(RouteProfile.motorbike),
        isTrue,
      );
    });

    test(
      'Vietmap honours neither toggle — route v4 has no exclusion parameter',
      () {
        for (final p in RouteProfile.values) {
          expect(RouteProvider.vietmap.canAvoidHighway(p), isFalse);
          expect(RouteProvider.vietmap.canAvoidFerry(p), isFalse);
        }
      },
    );

    test('OSRM loses avoid-highway on the motorcycle profile only', () {
      expect(
        RouteProvider.osrm.canAvoidHighway(RouteProfile.motorbike),
        isFalse,
      );
      expect(RouteProvider.osrm.canAvoidHighway(RouteProfile.car), isTrue);
      expect(RouteProvider.osrm.canAvoidFerry(RouteProfile.motorbike), isTrue);
    });

    test('the offline graph is car-only', () {
      expect(
        RouteProvider.graphhopper.canAvoidHighway(RouteProfile.car),
        isTrue,
      );
      expect(
        RouteProvider.graphhopper.canAvoidHighway(RouteProfile.motorbike),
        isFalse,
      );
    });

    test('only the on-device graph is offline', () {
      expect(RouteProvider.graphhopper.isOnline, isFalse);
      for (final p in [
        RouteProvider.google,
        RouteProvider.vietmap,
        RouteProvider.osrm,
      ]) {
        expect(p.isOnline, isTrue);
      }
    });
  });
}
