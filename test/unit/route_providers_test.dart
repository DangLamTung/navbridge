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
    test('default OSM source: car and motorbike may use the offline graph', () {
      expect(resolveRouteChain(RouteProfile.car), [
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
      // A motorbike is routed on the CAR graph: the archive carries no
      // motorcycle encodings. Bicycle/walking have no graph at all.
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
      for (final p in [RouteProfile.bicycle, RouteProfile.walking]) {
        expect(resolveRouteChain(p), [RouteProvider.osrm]);
      }
    });

    test('Google source is tried first, then offline graph, then OSRM', () {
      dataSource = 'google';
      expect(resolveRouteChain(RouteProfile.car), [
        RouteProvider.google,
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
      // Motorbike now falls back to the offline graph before OSRM too.
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.google,
        RouteProvider.graphhopper,
        RouteProvider.osrm,
      ]);
    });

    test('Vietmap serves car/motorbike only, and still falls back to OSRM', () {
      dataSource = 'vietmap';
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.vietmap,
        RouteProvider.graphhopper,
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
        // Fully offline, the motorbike rides the car graph rather than failing.
        expect(resolveRouteChain(RouteProfile.motorbike), [
          RouteProvider.graphhopper,
        ]);
        // …but a mode with no graph has nothing left.
        expect(resolveRouteChain(RouteProfile.bicycle), isEmpty);
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
      expect(resolveRouteChain(RouteProfile.motorbike), [
        RouteProvider.graphhopper,
      ]);

      routingEngine = 'osrm';
      expect(resolveRouteChain(RouteProfile.car), [RouteProvider.osrm]);
    });

    test('describeRouteChain spells the order out for the UI', () {
      expect(describeRouteChain(RouteProfile.car), 'GraphHopper → OSRM');
      dataSource = 'google';
      expect(
        describeRouteChain(RouteProfile.motorbike),
        'Google → GraphHopper → OSRM',
      );
      forceOffline = true;
      expect(
        describeRouteChain(RouteProfile.bicycle),
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

    test('the offline graph serves car and motorbike', () {
      expect(
        RouteProvider.graphhopper.canAvoidHighway(RouteProfile.car),
        isTrue,
      );
      // A motorbike rides the SAME car graph, so it inherits its behaviour.
      expect(
        RouteProvider.graphhopper.canAvoidHighway(RouteProfile.motorbike),
        isTrue,
      );
      expect(
        RouteProvider.graphhopper.canAvoidHighway(RouteProfile.bicycle),
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
