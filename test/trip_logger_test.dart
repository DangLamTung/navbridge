/// Tests for the Google-Takeout trip logger (`trip_logger.dart`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/trip_logger.dart';

void main() {
  group('defaultFileName', () {
    test('keeps Vietnamese diacritics, replaces spaces', () {
      final t = TripLogger(
        name: 'Chợ Bến Thành',
        startedAt: DateTime(2026, 8, 4, 9, 5, 7),
      );
      expect(t.defaultFileName, '2026-08-04_090507_Chợ_Bến_Thành.json');
    });

    test('replaces characters that are unsafe in filenames', () {
      final t = TripLogger(name: 'A!!B/C', startedAt: DateTime(2026, 1, 1));
      // Adjacent invalid characters collapse into a single underscore.
      expect(t.defaultFileName, contains('A_B_C'));
    });

    test('falls back to "trip" for an empty name', () {
      final t = TripLogger(name: '', startedAt: DateTime(2026, 1, 1));
      expect(t.defaultFileName, contains('_trip.json'));
    });
  });

  group('addFix sampling', () {
    test('first fix is always recorded', () {
      final t = TripLogger(name: 'x');
      t.addFix(const LatLng(10, 106));
      expect(t.fixCount, 1);
    });

    test('skips fixes that are too soon and too close', () {
      final t = TripLogger(name: 'x');
      t.addFix(const LatLng(10, 106));
      // Same instant, ~3 m away → under the 250 ms / 5 m debug thresholds.
      t.addFix(const LatLng(10.00002, 106.00002));
      expect(t.fixCount, 1);
    });

    test('records a fix that moved far enough', () {
      final t = TripLogger(name: 'x');
      t.addFix(const LatLng(10, 106));
      // ~1.1 km away → recorded even at the same instant.
      t.addFix(const LatLng(10.01, 106));
      expect(t.fixCount, 2);
    });
  });

  group('serialization', () {
    test('hasEnoughData requires at least two fixes', () {
      final t = TripLogger(name: 'x');
      expect(t.hasEnoughData, isFalse);
      t.addFix(const LatLng(10, 106));
      expect(t.hasEnoughData, isFalse);
      t.addFix(const LatLng(10.001, 106.001));
      expect(t.hasEnoughData, isTrue);
    });

    test(
      'toTakeoutJson matches the Google Takeout shape with velocity and timestamp',
      () {
        final t = TripLogger(name: 'Chợ Bến Thành');
        t.addFix(const LatLng(10.8231, 106.6297), speedMps: 8);
        t.finish();
        final j = t.toTakeoutJson();
        final locations = j['locations'] as List;
        expect(locations, hasLength(1));
        final loc = locations.first as Map<String, dynamic>;
        expect(loc['latitudeE7'], 108231000);
        expect(loc['longitudeE7'], 1066297000);
        expect(loc['velocity'], 8);
        expect(loc['timestamp'], isNotNull);
        expect(loc['timestampMs'], isNotNull);
        final activity =
            (loc['activity'] as List).first as Map<String, dynamic>;
        final inner =
            (activity['activity'] as List).first as Map<String, dynamic>;
        expect(inner['type'], 'IN_VEHICLE'); // speed > 2 m/s

        // Verify destination place is captured
        final places = j['places'] as List;
        expect(places, hasLength(1));
        final place = places.first as Map<String, dynamic>;
        expect(place['name'], 'Chợ Bến Thành');
      },
    );

    test('records the limit decision inputs so a value can be re-derived', () {
      final t = TripLogger(name: 'x');
      t.addFix(
        const LatLng(10.8231, 106.6297),
        speedMps: 8,
        streetName: 'Cách Mạng Tháng Tám',
        highway: 'tertiary',
        speedLimit: 50,
        limitEffective: 50,
        limitSource: 'road',
        limitLayer: 'city',
        vehicle: 'motorbike',
        oneway: false,
        lanes: 2,
        divided: false,
        urban: true,
      );
      t.finish();
      final loc =
          (t.toTakeoutJson()['locations'] as List).first
              as Map<String, dynamic>;
      // Which layer answered, for which vehicle class, from which road tags —
      // the complete input set of the statutory / built-up decision.
      expect(loc['limitLayer'], 'city');
      expect(loc['vehicle'], 'motorbike');
      expect(loc['oneway'], isFalse);
      expect(loc['lanes'], 2);
      expect(loc['divided'], isFalse);
      expect(loc['urban'], isTrue);
    });

    test('omits decision inputs that were unknown', () {
      final t = TripLogger(name: 'x');
      t.addFix(const LatLng(10.8231, 106.6297));
      t.finish();
      final loc =
          (t.toTakeoutJson()['locations'] as List).first
              as Map<String, dynamic>;
      expect(loc.containsKey('vehicle'), isFalse);
      expect(loc.containsKey('urban'), isFalse);
      expect(loc.containsKey('limitLayer'), isFalse);
    });

    test('tripDateLabel formats date as DD/MM/YYYY', () {
      final f = File('/path/to/2026-09-07_083000_Chợ_Bến_Thành.json');
      expect(tripDateLabel(f), '07/09/2026');
    });
  });

  // A drive killed mid-way (force stop, OOM, crash, battery pull) must not be
  // lost: every record is spooled to `<trip>.part` as one flushed JSON line.
  group('continuous write (spool)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('navbridge_spool'));
    tearDown(() => dir.deleteSync(recursive: true));

    List<String> spoolLines(TripLogger t) {
      final f = File('${dir.path}/${t.defaultFileName}.part');
      return f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    }

    void driveThreeFixes(TripLogger t) {
      t.addFix(const LatLng(10.0, 106.0), speedMps: 8);
      t.addFix(const LatLng(10.001, 106.001), speedMps: 8);
      t.addFix(const LatLng(10.002, 106.002), speedMps: 8);
    }

    test('writes every fix to disk as it happens, not only at save', () async {
      final t = TripLogger(name: 'Chuyến đi', spoolDir: dir);
      driveThreeFixes(t);
      t.logAnnouncement(
        const LatLng(10.001, 106.001),
        'Giới hạn 50 km/h',
        kind: 'limit',
      );
      await t.closeSpool();

      final lines = spoolLines(t);
      expect(lines, hasLength(4)); // 3 fixes + 1 announcement, none awaited
      final kinds = [for (final l in lines) (jsonDecode(l) as List).first];
      expect(kinds, ['f', 'f', 'f', 'a']);
      expect(t.spooledRecords, 4);
      // The line is a COMPLETE record on its own — that is what survives a kill.
      final fix = (jsonDecode(lines.first) as List)[1] as Map<String, dynamic>;
      expect(fix['latitudeE7'], 100000000);
    });

    test(
      'recoverSpooledTrips rebuilds a killed trip into a normal file',
      () async {
        final t = TripLogger(name: 'Chuyến đi', spoolDir: dir);
        driveThreeFixes(t);
        await t.closeSpool(); // the app dies here: no saveTrip() ever runs

        expect(spoolLines(t), hasLength(3));
        expect(await recoverSpooledTrips(dir: dir), 1);

        final out = File('${dir.path}/${t.defaultFileName}');
        expect(out.existsSync(), isTrue);
        final j = jsonDecode(out.readAsStringSync()) as Map<String, dynamic>;
        expect((j['locations'] as List), hasLength(3));
        expect(j['recovered'], isTrue);
        // The spool is a leftover once the trip exists.
        expect(File('${out.path}.part').existsSync(), isFalse);
      },
    );

    test('a torn last line (killed mid-write) is dropped, not fatal', () async {
      final t = TripLogger(name: 'x', spoolDir: dir);
      driveThreeFixes(t);
      await t.closeSpool();
      File(
        '${dir.path}/${t.defaultFileName}.part',
      ).writeAsStringSync('["f", {"latitudeE7": 999', mode: FileMode.append);

      expect(await recoverSpooledTrips(dir: dir), 1);
      final j =
          jsonDecode(
                File('${dir.path}/${t.defaultFileName}').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((j['locations'] as List), hasLength(3));
    });

    test('a spool that cannot be opened never breaks the trip', () async {
      // /dev/null is not a directory: opening the spool must fail softly.
      final t = TripLogger(name: 'x', spoolDir: Directory('/dev/null/trips'));
      driveThreeFixes(t);
      await t.closeSpool();

      expect(t.spooledRecords, 0);
      expect(t.fixCount, 3); // in-memory trip is intact
      expect((t.toTakeoutJson()['locations'] as List), hasLength(3));
    });
  });
}
