import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/trip_replay.dart';

/// The replay parser is the front door of the simulator: if it mis-reads a
/// recorded drive, every number the harness reports is wrong. So it is pinned
/// against the shapes the app writes (and the Google-Timeline shape
/// `tool/emulator_gps_replay.py` also handles), and against the real files in
/// `docs/trips/device/` when they are present on this machine.
///
/// The filter-side replay (StrictHeading + CarFilter + OutlierGate over a real
/// log) lives in `trip_replay_test.dart`; this file covers the source that
/// feeds the whole page.
void main() {
  group('parseReplayFixes — coordinates', () {

    test('3 cases', () {
    // ---- case: reads latitudeE7/longitudeE7 ----
    (() {
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":107971808,'
          '"longitudeE7":1066728939,"accuracy":10,"heading":35,"velocity":7.5}]',
        );
        expect(f, hasLength(1));
        expect(f.single.lat, closeTo(10.7971808, 1e-7));
        expect(f.single.lng, closeTo(106.6728939, 1e-7));
        expect(f.single.accuracy, 10);
        expect(f.single.speedMps, closeTo(7.5, 1e-9));
        expect(f.single.headingDeg, closeTo(35, 1e-9));

    })();


    // ---- case: reads plain latitude/longitude ----
    (() {
        final f = parseReplayFixes(
          '[{"timestamp":"2026-09-24T03:52:13.048694Z","latitude":10.5,'
          '"longitude":106.5,"accuracy":8}]',
        );
        expect(f.single.lat, closeTo(10.5, 1e-9));
        expect(f.single.lng, closeTo(106.5, 1e-9));
        expect(f.single.at.isUtc, isTrue);

    })();


    // ---- case: an accuracy of 0 is treated as "unknown", not as a perfect fix ----
    (() {
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000,"accuracy":0}]',
        );
        expect(f.single.accuracy, 10);

    })();
    });

  });

  group('parseReplayFixes — time', () {

    test('3 cases', () {
    // ---- case: timestampMs may be a string or a number ----
    (() {
        final asString = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":1e7,'
          '"longitudeE7":1.06e9}]',
        );
        final asNum = parseReplayFixes(
          '[{"timestampMs":1700000000000,"latitudeE7":1e7,"longitudeE7":1.06e9}]',
        );
        expect(asString.single.at, asNum.single.at);
        expect(
          asString.single.at,
          DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        );

    })();


    // ---- case: fixes are sorted by time even when the log is not ----
    (() {
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000003000","latitudeE7":1e7,'
          '"longitudeE7":1.06e9},'
          '{"timestampMs":"1700000001000","latitudeE7":1e7,'
          '"longitudeE7":1.06e9}]',
        );
        expect(
          f.first.at.isBefore(f.last.at),
          isTrue,
          reason: 'a drive must not run backwards because the file was unordered',
        );

    })();


    // ---- case: entries without a time or a position are dropped, not guessed at ----
    (() {
        final f = parseReplayFixes(
          '[{"latitudeE7":1e7,"longitudeE7":1.06e9},'
          '{"timestampMs":"1700000000000"},'
          '{"timestampMs":"1700000001000","latitudeE7":1e7,'
          '"longitudeE7":1.06e9}]',
        );
        expect(f, hasLength(1));

    })();
    });

  });

  group('parseReplayFixes — derived speed and heading', () {

    test('3 cases', () {
    // ---- case: derives speed and heading when the log has neither ----
    (() {
        // ~111 m due north in 10 s → ~11 m/s, heading 0.
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000,"accuracy":10},'
          '{"timestampMs":"1700000010000","latitudeE7":100010000,'
          '"longitudeE7":1060000000,"accuracy":10}]',
        );
        expect(f.last.speedMps, closeTo(11.1, 0.5));
        expect(f.last.headingDeg, closeTo(0, 1.5));
        expect(
          f.first.speedMps,
          0,
          reason: 'the first fix has no previous fix to measure against',
        );

    })();


    // ---- case: a stationary car in a jittery fix does not read as moving ----
    (() {
        // ~3 m of wander over 1 s is receiver noise, not a drive.
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000,"accuracy":10},'
          '{"timestampMs":"1700000001000","latitudeE7":100000027,'
          '"longitudeE7":1060000000,"accuracy":10}]',
        );
        expect(f.last.speedMps, 0);

    })();


    // ---- case: recorded speed and heading win over derived ones ----
    (() {
        final f = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000,"accuracy":10,"velocity":0,"heading":0},'
          '{"timestampMs":"1700000010000","latitudeE7":100010000,'
          '"longitudeE7":1060000000,"accuracy":10,"velocity":2.5,"heading":12}]',
        );
        expect(f.last.speedMps, 2.5);
        expect(f.last.headingDeg, 12);

    })();
    });

  });

  group('parseReplayFixes — junk in', () {
    test('garbage, empty and unexpected documents return no fixes', () {
      expect(parseReplayFixes(''), isEmpty);
      expect(parseReplayFixes('not json'), isEmpty);
      expect(parseReplayFixes('{}'), isEmpty);
      expect(parseReplayFixes('{"locations":[]}'), isEmpty);
      expect(parseReplayFixes('{"foo":[1,2,3]}'), isEmpty);
    });

    test('accepts a bare list of fixes (no `locations` wrapper)', () {
      final f = parseReplayFixes(
        '[{"timestampMs":"1700000000000","latitudeE7":1e7,'
        '"longitudeE7":1.06e9}]',
      );
      expect(f, hasLength(1));
    });
  });

  group('replayPositionStream', () {

    test('3 cases', () async {
    // ---- case: emits every fix, in order, with its own timestamp ----
    await (() async {
        final fixes = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000,"velocity":5,"heading":10},'
          '{"timestampMs":"1700000001000","latitudeE7":100001000,'
          '"longitudeE7":1060000000,"velocity":5,"heading":10},'
          '{"timestampMs":"1700000002000","latitudeE7":100002000,'
          '"longitudeE7":1060000000,"velocity":5,"heading":10}]',
        );
        final got = await replayPositionStream(fixes, speed: 0).toList();
        expect(got, hasLength(3));
        expect(got.first.timestamp, fixes.first.at);
        expect(got.last.timestamp, fixes.last.at);
        expect(got.last.latitude, closeTo(10.0002, 1e-9));

    })();


    // ---- case: speed compresses the gaps ----
    await (() async {
        final fixes = parseReplayFixes(
          '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
          '"longitudeE7":1060000000},'
          '{"timestampMs":"1700000001000","latitudeE7":100001000,'
          '"longitudeE7":1060000000}]',
        );
        final sw = Stopwatch()..start();
        await replayPositionStream(fixes, speed: 10).toList();
        sw.stop();
        // 1000 ms of drive at 10× = ~100 ms of wall time. The assertion is
        // "faster than real time", not a precise duration.
        expect(sw.elapsedMilliseconds, lessThan(500));

    })();


    // ---- case: an empty trip emits nothing rather than hanging ----
    await (() async {
        expect(await replayPositionStream(const [], speed: 1).toList(), isEmpty);

    })();
    });

  });

  group('trip metrics', () {
    test('measures the drive it was given', () {
      final fixes = parseReplayFixes(
        '[{"timestampMs":"1700000000000","latitudeE7":100000000,'
        '"longitudeE7":1060000000},'
        '{"timestampMs":"1700000060000","latitudeE7":100010000,'
        '"longitudeE7":1060000000}]',
      );
      expect(replayTripMeters(fixes), closeTo(111.2, 1.0));
      expect(replayTripDuration(fixes), const Duration(minutes: 1));
      expect(angleDeltaDeg(350, 10), closeTo(20, 1e-9));
      expect(angleDeltaDeg(10, 350), closeTo(20, 1e-9));
    });
  });

  group('TripReplay armed state', () {
    tearDown(() {
      TripReplay.injectedJson = null;
    });

    test('is unarmed by default, armed once a trip is injected', () {
      expect(TripReplay.armed, isFalse);
      expect(TripReplay.source, isNull);
      TripReplay.injectedJson = '{"locations":[]}';
      expect(TripReplay.armed, isTrue);
      expect(TripReplay.source, 'injected');
      // Speed defaults to real time when nothing says otherwise.
      expect(TripReplay.speed, 1);
    });

    test('loads and parses an injected trip without touching disk', () async {
      TripReplay.injectedJson =
          '{"locations":[{"timestampMs":"1700000000000",'
          '"latitudeE7":100000000,"longitudeE7":1060000000,"accuracy":10}]}';
      final fixes = await TripReplay.load();
      expect(fixes, hasLength(1));
      expect(fixes.single.lat, closeTo(10.0, 1e-9));
    });
  });

  group('the real recorded drives on this machine', () {
    final dir = Directory('docs/trips/device');
    final files = dir.existsSync()
        ? (dir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.json'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];

    test('every trip in docs/trips/device parses into a drivable track', () {
      if (files.isEmpty) {
        // `docs/trips/` is gitignored — a fresh clone has no recorded drives,
        // and that must not be a failure.
        return;
      }
      var checked = 0;
      var longDrives = 0;
      for (final f in files) {
        final fixes = parseReplayFixes(f.readAsStringSync());
        // Some logs on this machine are seconds long (a recording started and
        // stopped, a failed drive) — a short log is not a parse failure. What
        // must never happen is a log that yields one fix or none: that would
        // mean the parser missed a shape the app actually writes.
        expect(
          fixes.length,
          greaterThanOrEqualTo(2),
          reason: '${f.path} produced ${fixes.length} fixes',
        );
        if (fixes.length > 60) longDrives++;
        // Monotonic in time, no NaN, plausible speeds: a fix that fails this
        // would make the harness blame the algorithm for a parser bug.
        for (var i = 0; i < fixes.length; i++) {
          final x = fixes[i];
          expect(x.lat.isFinite && x.lng.isFinite, isTrue);
          expect(x.speedMps.isFinite && x.speedMps >= 0, isTrue);
          expect(x.speedMps, lessThan(60), reason: '${f.path} fix $i');
          if (i > 0) expect(x.at.isBefore(fixes[i - 1].at), isFalse);
        }
        checked++;
      }
      expect(checked, files.length);
      expect(
        longDrives,
        greaterThan(0),
        reason: 'the corpus should contain at least one drive worth replaying',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the newest recorded drive is a real drive, not a standstill', () {
      if (files.isEmpty) return;
      final fixes = parseReplayFixes(files.last.readAsStringSync());
      expect(replayTripDuration(fixes).inSeconds, greaterThan(30));
      expect(replayTripMeters(fixes), greaterThan(100));
    });
  });
}
