/// The Google request contract. These are the two things that used to be
/// wrong/invisible: a bicycle or walking route was requested with
/// `mode=driving`, and the "tránh cao tốc/phà" toggles never reached Google at
/// all. Both are pure builders, so this needs no key and no network.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/services/google_router.dart';

const _pts = [LatLng(10.78, 106.66), LatLng(10.79, 106.70)];
const _via = [
  LatLng(10.78, 106.66),
  LatLng(10.785, 106.68),
  LatLng(10.79, 106.70),
];

void main() {
  group('legacy Directions URL', () {
    test('car is mode=driving with no avoid when both toggles are off', () {
      final url = googleDirectionsUrl(points: _pts, key: 'K');
      expect(url, contains('mode=driving'));
      expect(url, isNot(contains('avoid=')));
    });

    test('avoid= is pipe-separated and lists only what was asked for', () {
      final both = googleDirectionsUrl(
        points: _pts,
        key: 'K',
        avoidHighway: true,
        avoidFerry: true,
      );
      expect(both, contains('avoid=highways|ferries'));

      final highway = googleDirectionsUrl(
        points: _pts,
        key: 'K',
        avoidHighway: true,
      );
      expect(highway, contains('avoid=highways'));
      expect(highway, isNot(contains('ferries')));

      final ferry = googleDirectionsUrl(
        points: _pts,
        key: 'K',
        avoidFerry: true,
      );
      expect(ferry, contains('avoid=ferries'));
      expect(ferry, isNot(contains('highways')));
    });

    test('bicycle/walking get their own mode instead of a driving route', () {
      expect(
        googleDirectionsUrl(
          points: _pts,
          key: 'K',
          profile: RouteProfile.bicycle,
        ),
        contains('mode=bicycling'),
      );
      expect(
        googleDirectionsUrl(
          points: _pts,
          key: 'K',
          profile: RouteProfile.walking,
        ),
        contains('mode=walking'),
      );
      // Motorbikes must not arrive here; the fallback stays a valid request.
      expect(googleTravelMode(RouteProfile.motorbike), 'driving');
    });

    test('walking never carries avoid= (the API ignores it there)', () {
      final url = googleDirectionsUrl(
        points: _pts,
        key: 'K',
        profile: RouteProfile.walking,
        avoidHighway: true,
        avoidFerry: true,
      );
      expect(url, isNot(contains('avoid=')));
    });

    test('waypoints use the pipe separator, and origin stays before dest', () {
      final url = googleDirectionsUrl(points: _via, key: 'K');
      expect(url, contains('waypoints=10.785,106.68'));
      expect(url, contains('alternatives=true'));
      expect(url.indexOf('origin='), lessThan(url.indexOf('destination=')));
      // The key and language must survive any refactor of the builder.
      expect(url, contains('key=K'));
      expect(url, contains('language=vi'));
    });

    test('single alternative disables the alternatives flag', () {
      final url = googleDirectionsUrl(
        points: _pts,
        key: 'K',
        maxAlternatives: 1,
      );
      expect(url, contains('alternatives=false'));
    });
  });

  group('Routes API v2 body (motorbike)', () {
    test('is TWO_WHEELER and carries no routeModifiers by default', () {
      final body = googleComputeRoutesBody(points: _pts);
      expect(body['travelMode'], 'TWO_WHEELER');
      expect(body.containsKey('routeModifiers'), isFalse);
    });

    test('avoid toggles become routeModifiers.avoidHighways/avoidFerries', () {
      final both = googleComputeRoutesBody(
        points: _pts,
        avoidHighway: true,
        avoidFerry: true,
      );
      expect(both['routeModifiers'], {
        'avoidHighways': true,
        'avoidFerries': true,
      });

      final highway = googleComputeRoutesBody(points: _pts, avoidHighway: true);
      expect(highway['routeModifiers'], {'avoidHighways': true});
    });

    test('intermediates are only sent for 3+ points', () {
      expect(
        googleComputeRoutesBody(points: _pts).containsKey('intermediates'),
        isFalse,
      );
      final withVia = googleComputeRoutesBody(points: _via);
      expect(withVia.containsKey('intermediates'), isTrue);
      expect((withVia['intermediates'] as List).length, 1);
    });
  });
}
