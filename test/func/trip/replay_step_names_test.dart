// The replay must NAME its steps from the recorded street.
//
// `routeFromTrack` used to give every step `name: ''`. The engine turns an
// unnamed step into its placeholder (`nav_engine.dart`:
// `cur.name.isNotEmpty ? cur.name : kContinuePlaceholder`), so a replayed drive
// showed "Tiến lên" in the banner from the first fix to the last — no street,
// no turn target, and `routeRoadNames()` empty, which also left the road-name
// veto with nothing to work with in the simulator.
//
// The name cannot be invented: a replay has no router, only the drive. So each
// step is named with the MAJORITY street the recording logs over that step's own
// fixes — the phone's own name for that leg, which is what a replay replays.

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/trip_replay.dart';

/// A straight north-going track turned right onto a second street, with the
/// street recorded on every fix.
List<ReplayFix> _track() {
  final out = <ReplayFix>[];
  final t0 = DateTime(2026, 9, 29, 8, 37, 15);
  // 40 fixes heading ~north on "Đường A", then 40 heading ~east on "Đường B".
  for (var i = 0; i < 40; i++) {
    out.add(
      ReplayFix(
        at: t0.add(Duration(seconds: i)),
        lat: 10.7900 + i * 2.5e-5,
        lng: 106.6300,
        accuracy: 8,
        speedMps: 8,
        headingDeg: 0,
        street: 'Đường A',
      ),
    );
  }
  for (var i = 0; i < 40; i++) {
    out.add(
      ReplayFix(
        at: t0.add(Duration(seconds: 40 + i)),
        lat: 10.7900 + 39 * 2.5e-5,
        lng: 106.6300 + (i + 1) * 2.5e-5,
        accuracy: 8,
        speedMps: 8,
        headingDeg: 90,
        street: 'Đường B',
      ),
    );
  }
  return out;
}

void main() {
  group('replay step names', () {
    final route = routeFromTrack(_track());

    test('the banner never has to fall back to "Tiến lên"', () {
      // Every step except "arrive" must carry a name the drive recorded; the
      // "arrive" step has no road of its own.
      for (final s in route.steps.where((s) => s.type != 'arrive')) {
        expect(
          s.name,
          isNotEmpty,
          reason: 'a step with no name prints "Tiến lên" in the banner',
        );
      }
    });

    test('each leg is named with the street driven on that leg', () {
      final named = route.steps
          .where((s) => s.type != 'arrive')
          .map((s) => s.name)
          .toSet();
      expect(named, containsAll(<String>['Đường A', 'Đường B']));
    });

    test('the step spanning the turn into Đường B is named Đường B', () {
      // The last step is the leg after the turn, i.e. the one the banner shows
      // once the car is through the junction.
      final legs = route.steps.where((s) => s.type != 'arrive').toList();
      expect(legs.last.name, 'Đường B');
    });

    test('naming changes nothing about the tiling the engine positions from', () {
      expect(route.steps.first.type, 'depart');
      expect(route.steps.last.type, 'arrive');
      final sum = route.steps.fold<double>(0, (a, s) => a + s.distance);
      expect(sum, closeTo(route.distance, 0.01));
    });

    test('a track with no recorded street still degrades to the placeholder', () {
      final bare = _track()
          .map(
            (f) => ReplayFix(
              at: f.at,
              lat: f.lat,
              lng: f.lng,
              accuracy: f.accuracy,
              speedMps: f.speedMps,
              headingDeg: f.headingDeg,
            ),
          )
          .toList();
      final r = routeFromTrack(bare);
      expect(r.steps.where((s) => s.type != 'arrive').every((s) => s.name.isEmpty), isTrue);
    });

    test('a single-fix track does not throw', () {
      final one = <ReplayFix>[
        ReplayFix(
          at: DateTime(2026, 9, 29),
          lat: 10.79,
          lng: 106.63,
          accuracy: 8,
          speedMps: 0,
          headingDeg: 0,
          street: 'Đường A',
        ),
      ];
      expect(() => routeFromTrack(one), returnsNormally);
    });

    test('an empty track does not throw', () {
      expect(() => routeFromTrack(const <ReplayFix>[]), returnsNormally);
    });
  });
}
