/// Tests for the route/road-type profiles (`route_profile.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/route_profile.dart';

void main() {
  group('RouteProfile', () {
    test('OSRM profile mapping (motorbike rides on the car network)', () {
      expect(RouteProfile.car.osrm, 'driving');
      expect(RouteProfile.motorbike.osrm, 'driving');
      expect(RouteProfile.bicycle.osrm, 'cycling');
      expect(RouteProfile.walking.osrm, 'walking');
    });

    test('Vietnamese labels', () {
      expect(RouteProfile.car.label, 'Ô tô');
      expect(RouteProfile.motorbike.label, 'Xe máy');
      expect(RouteProfile.bicycle.label, 'Xe đạp');
      expect(RouteProfile.walking.label, 'Đi bộ');
    });

    test('every profile is selectable and complete', () {
      expect(kRouteProfiles.length, 4);
      for (final p in kRouteProfiles) {
        expect(p.label, isNotEmpty);
        expect(p.osrm, isNotEmpty);
      }
    });
  });
}
