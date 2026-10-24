/// The right-hand rule has to cover the WAZE rows too — they are the biggest
/// source of boundary plates (2 225 `populated` + 962 `populated_end`), they
/// carry no `heading` at all (0 of 8 056), and they stand 1-39 m off the road
/// (measured: median ~9 m), so the side of the route IS the only signal.
///
/// Measured on the 2026-10-24 path: 17 Waze boundary plates within 150 m, of
/// which 9 stand LEFT of the direction of travel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_road_signs.dart';

const double _mDegLat = 111320.0;

/// A 1 km due-EAST route whose centreline runs [offsetM] metres north of [at].
/// Travelling east, the right-hand side is SOUTH of the line — so a plate at
/// [at] is on the driver's RIGHT when [offsetM] is positive.
List<LatLng> _eastRouteAt(LatLng at, double offsetM) {
  final lat = at.latitude + offsetM / _mDegLat;
  final lng0 = at.longitude - 500 / (_mDegLat * _cos(at.latitude));
  final lng1 = at.longitude + 500 / (_mDegLat * _cos(at.latitude));
  return [LatLng(lat, lng0), LatLng(lat, lng1)];
}

double _cos(double deg) {
  // cos via Math-free polynomial is not worth it here; the test only needs a
  // few decimals, so use the identity cos(x) = sin(x + π/2).
  return _sin(deg + 90);
}

double _sin(double deg) {
  final x = (deg % 360) * 3.141592653589793 / 180.0;
  var term = x;
  var sum = x;
  for (var i = 1; i < 9; i++) {
    term *= -x * x / ((2 * i) * (2 * i + 1));
    sum += term;
  }
  return sum;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a WAZE boundary plate is read only from the right-hand side', () async {
    final signs = await loadOfflineRoadSigns();
    // The public repo ships a stub sign DB (tool/stub_assets.sh), so this test
    // only means something where the real pack is present.
    final wazeBoundary = signs
        .where((s) => s.source == 'waze' && s.kind == RoadSignKind.populated)
        .firstOrNull;
    if (wazeBoundary == null) {
      markTestSkipped('bundled sign DB is a stub (see tool/stub_assets.sh)');
      return;
    }
    expect(wazeBoundary.heading, isNull, reason: 'Waze rows carry no heading');
    final at = LatLng(wazeBoundary.lat, wazeBoundary.lng);

    // Plate 10 m to the RIGHT of the eastbound line.
    final right = await signsAheadOnRoute(
      _eastRouteAt(at, 10).first,
      _eastRouteAt(at, 10),
      maxAheadMeters: 1000,
      lateralMeters: 60,
    );
    // Plate 10 m to the LEFT of it.
    final left = await signsAheadOnRoute(
      _eastRouteAt(at, -10).first,
      _eastRouteAt(at, -10),
      maxAheadMeters: 1000,
      lateralMeters: 60,
    );

    final rightHit = right.any(
      (a) => a.sign.lat == wazeBoundary.lat && a.sign.lng == wazeBoundary.lng,
    );
    final leftHit = left.any(
      (a) => a.sign.lat == wazeBoundary.lat && a.sign.lng == wazeBoundary.lng,
    );
    // ignore: avoid_print
    print(
      'plate ${at.latitude},${at.longitude}  right=$rightHit  left=$leftHit',
    );
    expect(rightHit, isTrue, reason: 'bên phải hướng đi thì phải đọc');
    expect(leftHit, isFalse, reason: 'bên trái hướng đi thì phải bỏ');
  });
}
