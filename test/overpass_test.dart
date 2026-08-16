/// Tests for the OSM road-info helpers (`overpass.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/overpass.dart';

void main() {
  group('parseMaxspeed', () {
    test('parses plain km/h values', () {
      expect(parseMaxspeed('50', 50), 50);
      expect(parseMaxspeed('40', 50), 40);
      expect(parseMaxspeed('50 km/h', 50), 50);
      expect(parseMaxspeed('60 km/h', 50), 60);
    });

    test('converts mph to km/h (OSM stores imperial verbatim)', () {
      expect(parseMaxspeed('30 mph', 50), 48);
      expect(parseMaxspeed('55 mph', 50), 89);
    });

    test('converts knots to km/h', () {
      expect(parseMaxspeed('10 knots', 50), 19);
    });

    test('falls back on unknown/non-speed values', () {
      expect(parseMaxspeed(null, 50), 50);
      expect(parseMaxspeed('', 50), 50);
      expect(parseMaxspeed('none', 50), 50);
      expect(parseMaxspeed('signals', 50), 50);
      expect(parseMaxspeed('variable', 50), 50);
      expect(parseMaxspeed('walk', 50), 50);
      expect(parseMaxspeed('nope', 50), 50);
      expect(parseMaxspeed('urban', 50), 50);
      expect(parseMaxspeed('rural', 50), 50);
    });

    test('takes the first value of multi-value / conditional tags', () {
      expect(parseMaxspeed('50;30', 50), 50);
      expect(parseMaxspeed('50-60', 50), 50);
      expect(parseMaxspeed('30 @ (06:00-22:00)', 50), 30);
    });

    test('rejects absurd values (typos / mis-decoded garbage)', () {
      // A real 50 km/h limit must never come back as "31" (a mis-decoded
      // GraphHopper max_speed bit-pattern) or "999" (a data typo).
      expect(parseMaxspeed('31', 50), 31); // 31 is plausible → kept
      expect(parseMaxspeed('999', 50), 50); // absurd → fallback
      expect(parseMaxspeed('3', 50), 50); // below 5 → fallback
      expect(parseMaxspeed('250', 50), 50); // above 200 → fallback
    });
  });

  group('classInfo', () {
    test('Vietnamese statutory defaults per road class', () {
      expect(classInfo('motorway'), ('Cao tốc', 120));
      expect(classInfo('trunk'), ('Quốc lộ', 90));
      expect(classInfo('primary'), ('Quốc lộ', 80));
      expect(classInfo('secondary'), ('Tỉnh lộ', 60));
      expect(classInfo('tertiary'), ('Đường huyện', 50));
      expect(classInfo('residential'), ('Đường dân sinh', 50));
      expect(classInfo('service'), ('Đường nội bộ', 30));
      expect(classInfo('unknown_class'), ('Đường', 50));
    });
  });
}
