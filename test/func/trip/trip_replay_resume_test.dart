// The console's Continue: a stopped run resumes at the fix it stopped on.
//
// Why it needs pinning: the resume point lives in a static next to the trip, and
// two things can silently go wrong — the stream starts at the wrong fix (a run
// that skips a stretch of the drive, or replays it), or the point is used for
// the WRONG trip (the panel's typed path vs a picked file), which would make a
// "continued" run read a different drive's first fixes.

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/trip_replay.dart';

List<ReplayFix> fixes(int n) => [
  for (var i = 0; i < n; i++)
    ReplayFix(
      at: DateTime.utc(2026, 9, 16, 20, 0, i),
      lat: 10.78 + i * 1e-5,
      lng: 106.63 + i * 1e-5,
      accuracy: 10,
      speedMps: 5,
      headingDeg: 90,
      street: 'Đường $i',
      highway: 'residential',
    ),
];

void main() {
  group('replayPositionStream from a fix', () {

    test('3 cases', () async {
    // ---- case: starts at the requested fix and yields the rest in order ----
    await (() async {
        final out = <double>[];
        await for (final p in replayPositionStream(fixes(10), speed: 0, from: 4)) {
          out.add(p.latitude);
        }
        expect(out, hasLength(6)); // 4..9
        expect(out.first, closeTo(10.78 + 4 * 1e-5, 1e-12));
        expect(out.last, closeTo(10.78 + 9 * 1e-5, 1e-12));

    })();


    // ---- case: from 0 is the whole drive ----
    await (() async {
        var n = 0;
        await for (final _ in replayPositionStream(fixes(5), speed: 0)) {
          n++;
        }
        expect(n, 5);

    })();


    // ---- case: an out-of-range from is clamped, never empty ----
    await (() async {
        var n = 0;
        await for (final _ in replayPositionStream(fixes(5), speed: 0, from: 99)) {
          n++;
        }
        expect(n, 1); // the last fix, not nothing

    })();
    });

  });

  group('the resume point', () {

    test('3 cases', () {
    // ---- case: is remembered per trip and cleared on demand ----
    (() {
        TripReplay.clearResume();
        expect(TripReplay.resumeFor('assets/trips/a.json'), 0);

        TripReplay.noteStopped('assets/trips/a.json', 120);
        expect(TripReplay.resumeFor('assets/trips/a.json'), 120);
        // A different trip has nothing to continue from.
        expect(TripReplay.resumeFor('assets/trips/b.json'), 0);

        TripReplay.clearResume('assets/trips/a.json');
        expect(TripReplay.resumeFor('assets/trips/a.json'), 0);

    })();


    // ---- case: a stop at 0 fixes records nothing ----
    (() {
        TripReplay.clearResume();
        TripReplay.noteStopped('assets/trips/a.json', 0);
        expect(TripReplay.resumeFor('assets/trips/a.json'), 0);

    })();


    // ---- case: start() carries the point to the run it is starting ----
    (() {
        TripReplay.clearResume();
        TripReplay.noteStopped('assets/trips/a.json', 77);
        // Continue: no explicit `from` ⇒ resumes where the trip stopped.
        TripReplay.start('assets/trips/a.json', speed: 4);
        expect(TripReplay.pendingFrom, 77);
        // Start over: an explicit 0 is what the "Bắt đầu" button sends.
        TripReplay.start('assets/trips/a.json', speed: 4, from: 0);
        expect(TripReplay.pendingFrom, 0);
        // A trip that was never run starts at the beginning.
        TripReplay.clearResume();
        TripReplay.start('assets/trips/b.json', speed: 4);
        expect(TripReplay.pendingFrom, 0);

    })();
    });

  });
}
