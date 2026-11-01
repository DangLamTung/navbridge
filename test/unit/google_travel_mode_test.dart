/// Google's travel modes for the three road vehicles this app plans for.
///
/// ô tô → `DRIVE`, xe máy → `TWO_WHEELER`, xe tải → `TRUCK` (+ `vehicleInfo`,
/// which Google REQUIRES before it will route a lorry). Probed 2026-10-31
/// against the live API: all three answer 200 on the same 71–75 km corridor,
/// with 11–27 `speedReadingIntervals` — the intervals are what colour the line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/google_router.dart';

const _points = [LatLng(10.7769, 106.7009), LatLng(10.36, 106.36)];

void main() {
  group('travel mode', () {
    test('each road vehicle gets its own Google mode', () {
      expect(googleRoutesV2TravelMode(RouteProfile.car), 'DRIVE');
      expect(googleRoutesV2TravelMode(RouteProfile.motorbike), 'TWO_WHEELER');
      expect(googleRoutesV2TravelMode(RouteProfile.truck), 'TRUCK');
      expect(googleRoutesV2TravelMode(RouteProfile.bicycle), 'BICYCLE');
      expect(googleRoutesV2TravelMode(RouteProfile.walking), 'WALK');
    });

    test('two-wheelers and lorries bill at the Enterprise tier', () {
      expect(googleIsEnterpriseTier(RouteProfile.motorbike), isTrue);
      expect(googleIsEnterpriseTier(RouteProfile.truck), isTrue);
      expect(googleIsEnterpriseTier(RouteProfile.car), isFalse);
    });
  });

  group('request body', () {
    test('a lorry carries the vehicle attributes Google demands', () {
      final body = googleComputeRoutesBody(
        points: _points,
        profile: RouteProfile.truck,
      );
      expect(body['travelMode'], 'TRUCK');
      final mods = body['routeModifiers'] as Map;
      expect((mods['vehicleInfo'] as Map)['emissionType'], 'DIESEL');
    });

    test('a car sends no vehicle attributes', () {
      final body = googleComputeRoutesBody(
        points: _points,
        profile: RouteProfile.car,
      );
      expect(body['travelMode'], 'DRIVE');
      expect(body.containsKey('routeModifiers'), isFalse);
    });

    test('traffic intervals are requested in every mode', () {
      for (final p in [
        RouteProfile.car,
        RouteProfile.motorbike,
        RouteProfile.truck,
      ]) {
        final body = googleComputeRoutesBody(points: _points, profile: p);
        expect(body['extraComputations'], ['TRAFFIC_ON_POLYLINE']);
        expect(body['routingPreference'], 'TRAFFIC_AWARE');
        expect(body['polylineQuality'], 'HIGH_QUALITY');
      }
    });

    test('the departure time is a future UTC timestamp', () {
      final body = googleComputeRoutesBody(points: _points);
      final dep = body['departureTime'] as String;
      expect(dep, endsWith('Z'));
      final t = DateTime.parse(dep);
      expect(t.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('avoid flags ride along with the lorry attributes', () {
      final body = googleComputeRoutesBody(
        points: _points,
        profile: RouteProfile.truck,
        avoidFerry: true,
      );
      final mods = body['routeModifiers'] as Map;
      expect(mods['avoidFerries'], isTrue);
      expect(mods['vehicleInfo'], isNotNull);
    });

    test('waypoints become intermediates, not vias', () {
      final body = googleComputeRoutesBody(
        points: [_points.first, const LatLng(10.5, 106.5), _points.last],
      );
      expect((body['intermediates'] as List).length, 1);
    });
  });

  test('the truck profile is selectable and drives at lorry speeds', () {
    expect(kRouteProfiles.contains(RouteProfile.truck), isTrue);
    expect(RouteProfile.truck.label, 'Xe tải');
    expect(RouteProfile.truck.legalMaxKmh, 80);
    expect(RouteProfile.truck.osrm, 'driving');
  });
}
