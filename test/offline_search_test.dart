/// Offline geocoding: the bundled Việt Nam place index must return results
/// with NO network (forceOffline) — not just previously-cached online hits.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/offline_tiles.dart' show forceOffline;
import 'package:navbridge/osm_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => forceOffline = true);
  tearDown(() => forceOffline = false);

  test('offline geocoding finds a city from the bundled index', () async {
    final r = await osmAutocomplete('đà lạt');
    expect(r, isNotEmpty, reason: 'offline search should return results');
    expect(r.any((s) => s.display.contains('Đà Lạt')), isTrue);
  });

  test('offline search matches without accents / lowercase', () async {
    final r = await osmAutocomplete('ha noi');
    expect(r.any((s) => s.display.contains('Hà Nội')), isTrue);
  });

  test('offline search matches a district', () async {
    final r = await osmAutocomplete('ben thanh');
    expect(r.any((s) => s.display.contains('Bến Thành')), isTrue);
  });

  test('offline results carry real coordinates (not 0,0)', () async {
    final r = await osmAutocomplete('da lat');
    expect(r, isNotEmpty);
    expect(r.first.lat, closeTo(11.94, 0.1));
    expect(r.first.lng, closeTo(108.46, 0.1));
  });
}
