/// End-to-end proof that the app's OWN sign scan honours `heading`: at a real
/// khu dân cư boundary the pack holds two plates 42 m apart facing opposite
/// ways, and each direction must see exactly one of them.
///
/// The pair used here is from the bundled pack (Cao Bằng, R.420 heading 310 /
/// R.421 heading 152), so this also fails if a rebuild drops the `heading`
/// field from the asset.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_road_signs.dart';

/// A straight 1 km route through [at] travelling on [headingDeg].
List<LatLng> _routeThrough(LatLng at, double headingDeg) {
  const mPerDeg = 111320.0;
  final rad = headingDeg * 3.141592653589793 / 180.0;
  LatLng step(double m) => LatLng(
    at.latitude + m * _cos(rad) / mPerDeg,
    at.longitude +
        m * _sin(rad) / (mPerDeg * _cos(at.latitude * 3.141592653589793 / 180)),
  );
  return [step(-300), step(0), step(300), step(600)];
}

double _cos(double r) => _sin(r + 1.5707963267948966);
double _sin(double r) {
  // Taylor is plenty for the test's ~1e-4 rad accuracy.
  final x = r % 6.283185307179586;
  var term = x;
  var sum = x;
  for (var i = 1; i < 8; i++) {
    term *= -x * x / ((2 * i) * (2 * i + 1));
    sum += term;
  }
  return sum;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const boundary = LatLng(22.158292, 102.565017);

  test('driving one way sees only the plate facing that way', () async {
    final north = await signsAheadOnRoute(
      _routeThrough(boundary, 310).first,
      _routeThrough(boundary, 310),
      maxAheadMeters: 1000,
      lateralMeters: 60,
    );
    final kinds = north.map((a) => a.sign.kind).toSet();
    // ignore: avoid_print
    print(
      'heading 310 → ${north.map((a) => '${a.sign.kind.key}@${a.sign.heading}').toList()}',
    );
    expect(kinds.contains(RoadSignKind.populated), isTrue);
    expect(
      kinds.contains(RoadSignKind.populatedEnd),
      isFalse,
      reason: 'the R.421 plate faces 152 — it is the OTHER direction\'s',
    );
  });

  test('the opposite direction sees only its own plate', () async {
    final south = await signsAheadOnRoute(
      _routeThrough(boundary, 152).first,
      _routeThrough(boundary, 152),
      maxAheadMeters: 1000,
      lateralMeters: 60,
    );
    final kinds = south.map((a) => a.sign.kind).toSet();
    // ignore: avoid_print
    print(
      'heading 152 → ${south.map((a) => '${a.sign.kind.key}@${a.sign.heading}').toList()}',
    );
    expect(kinds.contains(RoadSignKind.populatedEnd), isTrue);
    expect(kinds.contains(RoadSignKind.populated), isFalse);
  });
}
