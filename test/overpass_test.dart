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
      expect(classInfo('unknown_class'), ('Đường', 50));
    });

    test('non-drivable classes have NO label (not real roads)', () {
      // service/footway/pedestrian/cycleway aren't roads for motor vehicles —
      // showing "Đường nội bộ"/"Lối đi bộ" as the road type was misleading.
      expect(classInfo('service'), ('', 30));
      expect(classInfo('footway'), ('', 10));
      expect(classInfo('pedestrian'), ('', 10));
      expect(classInfo('cycleway'), ('', 20));
      expect(classInfo('living_street'), ('', 20));
    });
  });

  group('statutoryLimit', () {
    test('per-vehicle defaults differ by road class', () {
      // Cars: motorway 120, primary 80.
      expect(statutoryLimit('motorway', vehicle: 'car'), 120);
      expect(statutoryLimit('primary', vehicle: 'car'), 80);
      // Motorbikes are capped lower (and banned on motorways — capped, not 0).
      // Thông tư 38/2024/TT-BGTVT: QL (trunk/primary) outside populated
      // 2-way = 60 km/h, urban 2-way = 50.
      expect(statutoryLimit('motorway', vehicle: 'motorbike'), 80);
      expect(statutoryLimit('trunk', vehicle: 'motorbike'), 60);
      expect(statutoryLimit('primary', vehicle: 'motorbike'), 60);
      expect(statutoryLimit('secondary', vehicle: 'motorbike'), 60);
      expect(statutoryLimit('residential', vehicle: 'motorbike'), 50);
      // Trucks lower still.
      expect(statutoryLimit('primary', vehicle: 'truck'), 60);
    });
  });

  group('effectiveLimit', () {
    test('car uses the tagged posted limit when present', () {
      expect(effectiveLimit('primary', vehicle: 'car', taggedKmh: 80), 80);
      expect(effectiveLimit('primary', vehicle: 'car', taggedKmh: 50), 50);
    });

    test('car falls back to the statutory class default when untagged', () {
      expect(effectiveLimit('primary', vehicle: 'car'), 80);
      expect(effectiveLimit('motorway', vehicle: 'car'), 120);
    });

    test('motorbike never inherits the car posted limit (OSM is car data)', () {
      // A primary posted 80 for cars must NOT show 80 for a motorbike —
      // the VN statutory motorbike default (60) wins.
      expect(
        effectiveLimit('primary', vehicle: 'motorbike', taggedKmh: 80),
        60,
      );
      expect(
        effectiveLimit('motorway', vehicle: 'motorbike', taggedKmh: 120),
        80,
      );
    });

    test(
      'motorbike is capped by a posted limit LOWER than its statutory default',
      () {
        // A residential posted 30 applies to motorbikes too → 30, not 50.
        expect(
          effectiveLimit('residential', vehicle: 'motorbike', taggedKmh: 30),
          30,
        );
      },
    );

    test('truck behaves like motorbike (statutory, capped by lower tag)', () {
      expect(effectiveLimit('primary', vehicle: 'truck', taggedKmh: 80), 60);
      expect(effectiveLimit('secondary', vehicle: 'truck', taggedKmh: 40), 40);
    });

    test('untagged non-car vehicles use their statutory default', () {
      expect(effectiveLimit('trunk', vehicle: 'motorbike'), 60);
      expect(effectiveLimit('trunk', vehicle: 'truck'), 70);
    });
  });

  group('parseOneway / parseLanes', () {
    test('oneway tag → true / false / unknown', () {
      expect(parseOneway('yes'), true);
      expect(parseOneway('true'), true);
      expect(parseOneway('1'), true);
      expect(parseOneway('-1'), true); // reverse one-way — still one-way
      expect(parseOneway('reverse'), true);
      expect(parseOneway('no'), false);
      expect(parseOneway('false'), false);
      expect(parseOneway('0'), false);
      expect(parseOneway(null), null);
      expect(parseOneway('alternating'), null); // no usable signal
    });

    test('lanes tag → per-carriageway count, junk ignored', () {
      expect(parseLanes('2'), 2);
      expect(parseLanes(3), 3);
      expect(parseLanes('2;3'), 2); // multi-value → first
      expect(parseLanes('1'), 1);
      expect(parseLanes('0'), null);
      expect(parseLanes('99'), null); // typo, not a real road
      expect(parseLanes('n/a'), null);
      expect(parseLanes(null), null);
    });
  });

  group('urbanLimit (khu đông dân cư — Thông tư 38/2024)', () {
    test('đường đôi / một chiều ≥2 làn → 60', () {
      expect(urbanLimit(vehicle: 'motorbike', oneway: true, lanes: 2), 60);
      expect(urbanLimit(vehicle: 'car', oneway: true, lanes: 3), 60);
      // lanes untagged on a one-way street → assumed ≥2 (one-way through
      // street). Keeps the value stable across a road's mixed tagging.
      expect(urbanLimit(vehicle: 'motorbike', oneway: true), 60);
      // An explicit opposite carriageway alongside = đường đôi.
      expect(urbanLimit(vehicle: 'car', oneway: false, divided: true), 60);
    });

    test('đường hai chiều / một chiều một làn → 50', () {
      expect(urbanLimit(vehicle: 'motorbike', oneway: false), 50);
      expect(urbanLimit(vehicle: 'car', oneway: false, lanes: 2), 50);
      expect(urbanLimit(vehicle: 'car'), 50); // both tags unknown
      expect(urbanLimit(vehicle: 'car', oneway: true, lanes: 1), 50);
    });

    test('truck is one step lower (50 / 40)', () {
      expect(urbanLimit(vehicle: 'truck', oneway: true, lanes: 2), 50);
      expect(urbanLimit(vehicle: 'truck', oneway: false), 40);
    });
  });

  group('built-up street classes use the road-form rule', () {
    test(
      'residential is 50 two-way, 60 on a divided / one-way ≥2 làn road',
      () {
        // Regression: this is the Lũy Bán Bích case — a secondary/residential
        // street that is a 60 km/h đường đôi read 50 everywhere, because the
        // built-up limit was frozen at the boundary regardless of road form.
        expect(statutoryLimit('residential', vehicle: 'car'), 50);
        expect(statutoryLimit('residential', vehicle: 'motorbike'), 50);
        expect(
          statutoryLimit('residential', vehicle: 'motorbike', oneway: true),
          60,
        );
        expect(
          statutoryLimit('residential', vehicle: 'car', divided: true),
          60,
        );
        expect(
          statutoryLimit('tertiary', vehicle: 'car', oneway: true),
          50, // higher classes keep their class default (urban/rural unknown)
        );
      },
    );

    test('effectiveLimit forwards the road-form signals', () {
      expect(effectiveLimit('residential', vehicle: 'car', oneway: true), 60);
      expect(effectiveLimit('residential', vehicle: 'car', oneway: false), 50);
    });
  });
}
