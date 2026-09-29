/// A segment the car is RIDING must not be excluded by a name we hold.
///
/// Measured on the 2026-09-29 08:37 drive, in the Trường Chinh turn
/// (10.79912,106.64196 → 10.79951,106.64129): the road matcher returned
/// **Trương Công Định** (tertiary, running ACROSS the car) instead of
/// **Trường Chinh** (primary, the road the car is riding ALONG), so the page
/// passed `expectStreet: 'Trương Công Định'`.
///
/// The lookup then narrowed its candidate pool to the expected name *before*
/// scoring any geometry, so it answered from the crossing record — and because
/// the answer agreed with the wrong name, nothing downstream could catch it. The
/// device's own log shows the result for 29 consecutive fixes:
///
///     street(published)  speedLimit  limitSource  limitLayer
///     Trương Công Định        50         road        segment
///
/// while the segment under the car posts **Trường Chinh 60**. That log is why
/// this is an app bug and not a simulator artefact.
///
/// Per-fix line angle of the winning segment (0° = the car rides along it):
///
///     fix 293  hdg 338  Trường Chinh 7.1 m  40°   ← the two roads merge here
///     fix 294  hdg 301  Trường Chinh 7.4 m   3°   Trương Công Định 13.6 m  77°
///     fix 298  hdg 281  Trường Chinh 4.7 m  17°   Trương Công Định 36.6 m
///     fix 301  hdg 297  Trường Chinh 4.6 m   1°
///
/// Fix 293 is the junction itself, where both roads sit ~40° off the heading and
/// the 45° test cannot separate them; from 294 on it separates them cleanly.
/// This uses the shipped pack, like the pinned `expectStreet` cases next door.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/road_match.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

/// Fix 294 — 7.4 m from Trường Chinh at 3° off the heading, 13.6 m from
/// Trương Công Định at 77° off it.
const _riding = LatLng(10.79915, 106.64191);

/// Fix 298 — 4.7 m from Trường Chinh at 17°; Trương Công Định is out at 36.6 m.
const _riding2 = LatLng(10.79924, 106.64169);

/// Fix 293 — the junction, both roads ~40° off the heading.
const _junction = LatLng(10.79912, 106.64196);

const _crossing = 'Trương Công Định';

void main() {
  // `loadOfflineSpeedLimits()` reads the pack through `rootBundle`, which needs
  // a binding — without it EVERY lookup answers null and the tests would "pass"
  // for the wrong reason (the sibling suite calls this too).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a ridden segment outranks a name we hold', () {
    setUp(() async {
      await loadOfflineSpeedLimits();
    });

    test('the wrong expectStreet cannot force the crossing road\'s value',
        () async {
      final hit = await lookupSpeedLimit(_riding, headingDeg: 301, expectStreet: _crossing);
      expect(hit, isNotNull, reason: 'the layer has a record right here');
      expect(hit!.limit, 60,
          reason: 'Trường Chinh posts 60; 50 is the CROSSING Trương Công Định');
      expect(hit.streetName, isNot(contains(_crossing)));
      expect(hit.aligned, isTrue, reason: 'the car is riding this segment');
    });

    test('and the same answer with no expectStreet at all', () async {
      final hit = await lookupSpeedLimit(_riding, headingDeg: 301);
      expect(hit?.limit, 60);
      expect(hit?.aligned, isTrue);
    });

    test('an unknown heading does NOT claim the car is riding the segment',
        () async {
      // The page sends `_heading == 0 ? null : _heading`, i.e. null for the first
      // seconds of every drive and permanently for the overlay. `ridden` turns
      // the name veto off, and `segmentScore` cannot penalise an across-the-car
      // candidate without a heading either — so "unknown" must read as
      // NOT riding, or a crossing street's value and name get adopted unchecked.
      final hit = await lookupSpeedLimit(_riding);
      expect(hit, isNotNull);
      expect(hit!.aligned, isFalse,
          reason: 'no heading means we cannot tell across from along');
    });

    test('mid-stretch, where the crossing road is out of range anyway',
        () async {
      final hit =
          await lookupSpeedLimit(_riding2, headingDeg: 281, expectStreet: _crossing);
      expect(hit?.limit, 60);
      expect(hit?.aligned, isTrue);
    });

    test('at the junction itself the layer still answers in range', () async {
      // Both roads are ~40° off the heading here, so the name is allowed to
      // decide which record is meant — but the answer must still be a record
      // inside the radius, never one reached for from across the pack.
      final hit = await lookupSpeedLimit(_junction, headingDeg: 338);
      expect(hit, isNotNull);
      debugPrint('junction: limit=${hit!.limit} street=${hit.streetName} '
          'aligned=${hit.aligned}');
    });

    test('layerLimitMatchesNames lets a ridden segment through, and no other',
        () {
      // The name on screen is the crossing street's; the segment is ridden.
      expect(
        layerLimitMatchesNames(
          segmentName: 'Trường Chinh',
          settled: _crossing,
          osmName: _crossing,
          routeNames: const <String>{_crossing},
          ridden: true,
        ),
        isTrue,
      );
      // The same disagreement, but the winner is not the road under the car (a
      // crossing street's record): the veto still applies.
      expect(
        layerLimitMatchesNames(
          segmentName: 'Trường Chinh',
          settled: _crossing,
          osmName: _crossing,
          routeNames: const <String>{_crossing},
        ),
        isFalse,
      );
    });
  });
}
