/// Tests for the route/road-type profiles (`route_profile.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/route_profile.dart';

void main() {
  group('RouteProfile', () {
    test('OSRM profile mapping (motorbike rides on the car network)', () {
      expect(RouteProfile.car.osrm, 'driving');
      // The motorbike profile is NAMED `motorcycle`. Verified against the
      // public server on 2026-09-20: both `driving` and `motorcycle` return
      // 200 with an IDENTICAL route (10,263 m for a Bình Thạnh → Quận 7
      // probe), so router.project-osrm.org still routes two-wheelers on the
      // car network; the distinct name only matters against a self-hosted
      // motorcycle profile.
      expect(RouteProfile.motorbike.osrm, 'motorcycle');
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
