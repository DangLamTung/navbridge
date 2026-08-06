/// Tests for the Google-Takeout trip logger (`trip_logger.dart`).
library;

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
      // Same instant, ~15 m away → under the 5 s / 20 m thresholds.
      t.addFix(const LatLng(10.0001, 106.0001));
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

    test('toTakeoutJson matches the Google Takeout shape', () {
      final t = TripLogger(name: 'x');
      t.addFix(const LatLng(10.8231, 106.6297), speedMps: 8);
      final j = t.toTakeoutJson();
      final locations = j['locations'] as List;
      expect(locations, hasLength(1));
      final loc = locations.first as Map<String, dynamic>;
      expect(loc['latitudeE7'], 108231000);
      expect(loc['longitudeE7'], 1066297000);
      final activity = (loc['activity'] as List).first as Map<String, dynamic>;
      final inner =
          (activity['activity'] as List).first as Map<String, dynamic>;
      expect(inner['type'], 'IN_VEHICLE'); // speed > 2 m/s
    });
  });
}
