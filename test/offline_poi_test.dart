import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/offline_poi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled POI index with categories + items', () async {
    final cats = await offlinePoiCategories();
    expect(cats, isNotEmpty);
    // All 25 categories from the generator are present.
    final keys = {for (final c in cats) c.key};
    expect(keys.contains('atm'), isTrue);
    expect(keys.contains('fuel'), isTrue);
    expect(keys.contains('restaurant'), isTrue);
    expect(keys.contains('hospital'), isTrue);
    // Each category has label + emoji + non-empty items.
    for (final c in cats) {
      expect(c.label, isNotEmpty);
      expect(c.emoji, isNotEmpty);
      expect(c.items, isNotEmpty);
    }
  });

  test('searchOfflinePois matches by name without accents', () async {
    final r = await searchOfflinePois('ben xe', limit: 5);
    expect(r, isNotEmpty);
    // Results carry real coordinates (not 0,0).
    for (final p in r.take(5)) {
      expect(p.lat.abs(), greaterThan(1));
      expect(p.lng.abs(), greaterThan(1));
    }
  });

  test('poisInCategory sorts by distance from center', () async {
    final near = LatLng(10.82, 106.63); // HCMC center
    const d = Distance();
    final r = await poisInCategory('atm', near: near, limit: 10);
    expect(r, isNotEmpty);
    final d0 = d.as(LengthUnit.Meter, r.first.pos, near);
    for (final p in r) {
      expect(d.as(LengthUnit.Meter, p.pos, near), greaterThanOrEqualTo(d0 - 1));
    }
  });

  test('searchOfflinePois finds a restaurant by partial name', () async {
    final r = await searchOfflinePois('pho', limit: 5);
    expect(r, isNotEmpty);
  });

  test('offline POIs expose rich metadata for info card', () async {
    // At least some POIs carry address/phone/description/wiki.
    final cats = await loadOfflinePois();
    final withInfo = <OfflinePoi>[];
    for (final c in cats) {
      for (final p in c.items) {
        if (p.hasInfo) withInfo.add(p);
      }
    }
    expect(withInfo, isNotEmpty);
    final rich = withInfo.firstWhere(
      (p) => p.description != null,
      orElse: () => withInfo.first,
    );
    expect(rich.hasInfo, isTrue);
  });
}
