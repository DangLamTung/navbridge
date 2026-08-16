/// Pure helpers for Vietnamese house-number / date-street address search:
/// "62 đường 30/4" → house "62" + street "đường 30/4" → rewritten street
/// "đường 30 Tháng 4" (the form OSM actually names it).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/osm_api.dart';

void main() {
  group('splitHouseNumber', () {
    test('splits a simple house number + street', () {
      final r = splitHouseNumber('62 đường 30/4');
      expect(r, isNotNull);
      expect(r!.$1, '62');
      expect(r.$2, 'đường 30/4');
    });

    test('handles house number with letter suffix (62A)', () {
      final r = splitHouseNumber('62A Trần Hưng Đạo');
      expect(r, isNotNull);
      expect(r!.$1, '62A');
      expect(r.$2, 'Trần Hưng Đạo');
    });

    test('handles alley-style house number (62/8)', () {
      final r = splitHouseNumber('62/8 Lê Lợi');
      expect(r, isNotNull);
      expect(r!.$1, '62/8');
      expect(r.$2, 'Lê Lợi');
    });

    test('handles letter-suffixed alley number (62/8A)', () {
      final r = splitHouseNumber('62/8A Nguyễn Huệ');
      expect(r, isNotNull);
      expect(r!.$1, '62/8A');
      expect(r.$2, 'Nguyễn Huệ');
    });

    test('returns null when there is no leading house number', () {
      expect(splitHouseNumber('Đường 30/4'), isNull);
      expect(splitHouseNumber('Chợ Bến Thành'), isNull);
    });
  });

  group('rewriteDateStreet', () {
    test('rewrites 30/4 to 30 Tháng 4 inside a full address', () {
      expect(rewriteDateStreet('62 đường 30/4'), '62 đường 30 Tháng 4');
    });

    test('rewrites the street part after a house number', () {
      final split = splitHouseNumber('62 đường 30/4')!;
      expect(rewriteDateStreet(split.$2), 'đường 30 Tháng 4');
    });

    test('accepts - and . separators', () {
      expect(rewriteDateStreet('đường 30-4'), 'đường 30 Tháng 4');
      expect(rewriteDateStreet('đường 30.4'), 'đường 30 Tháng 4');
    });

    test('ignores non-date numbers (alley 130/21, day > 31)', () {
      expect(rewriteDateStreet('Hẻm 130/21'), isNull);
      expect(rewriteDateStreet('Đường 40/13'), isNull); // day 40 > 31
    });

    test('returns null when nothing to rewrite', () {
      expect(rewriteDateStreet('Trần Hưng Đạo'), isNull);
    });
  });
}
