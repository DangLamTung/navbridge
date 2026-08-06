/// Tests for the OSRM client helpers (`osrm.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/osrm.dart';

void main() {
  group('decodePolyline', () {
    test('decodes a known single-point polyline', () {
      final pts = decodePolyline('_p~iF~ps|U');
      expect(pts.length, 1);
      expect(pts.first.latitude, closeTo(38.5, 1e-5));
      expect(pts.first.longitude, closeTo(-120.2, 1e-5));
    });

    test('decodes the OSRM docs multi-point example', () {
      final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(pts.length, 3);
      expect(pts[0].latitude, closeTo(38.5, 1e-4));
      expect(pts[0].longitude, closeTo(-120.2, 1e-4));
      expect(pts[1].latitude, closeTo(40.7, 1e-4));
      expect(pts[1].longitude, closeTo(-120.95, 1e-4));
      expect(pts[2].latitude, closeTo(43.252, 1e-4));
      expect(pts[2].longitude, closeTo(-126.453, 1e-4));
    });

    test('empty string yields an empty list', () {
      expect(decodePolyline(''), isEmpty);
    });
  });

  group('distanceMeters', () {
    test('zero for the same point', () {
      const a = LatLng(10.8231, 106.6297);
      expect(distanceMeters(a, a), 0);
    });

    test('one degree of longitude at the equator ≈ 111 km', () {
      final d = distanceMeters(const LatLng(0, 0), const LatLng(0, 1));
      expect(d, closeTo(111195, 200));
    });

    test('is symmetric', () {
      const a = LatLng(10.82, 106.63);
      const b = LatLng(21.03, 105.85);
      expect(distanceMeters(a, b), closeTo(distanceMeters(b, a), 1e-6));
    });
  });

  group('osrmExclude', () {
    test('null when nothing is avoided', () {
      expect(osrmExclude(avoidHighway: false, avoidFerry: false), isNull);
    });

    test('highway-only / ferry-only', () {
      expect(osrmExclude(avoidHighway: true, avoidFerry: false), 'motorway');
      expect(osrmExclude(avoidHighway: false, avoidFerry: true), 'ferry');
    });

    test('combines both, motorway first (most undesirable first)', () {
      expect(
        osrmExclude(avoidHighway: true, avoidFerry: true),
        'motorway,ferry',
      );
    });
  });
}
