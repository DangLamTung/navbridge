/// Tests for the ESP32 2.8" display binary protocol (`map_protocol.dart`).
///
/// Mirrors the board-side decoder in `ESP32_OSM_NAV/src/ble/ble_nav.cpp` so
/// the byte layout is verified against the real firmware's expectations.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/map_protocol.dart';
import 'package:navbridge/core/nav_protocol.dart';

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _i16(Uint8List b, int o) => (b[o] | (b[o + 1] << 8)).toSigned(16);
int _i32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)).toSigned(32);

/// Decode a route frame exactly like `parseRouteBin` in ble_nav.cpp.
(int type, int zoom, int count, List<(double, double)> pts) _decodeRoute(
  Uint8List f,
) {
  expect(f[0], mapFrameMagic0);
  expect(f[1], mapFrameMagic1);
  final payload = Uint8List.sublistView(f, 5);
  final zoom = payload[0];
  final count = _u16(payload, 1);
  var lat = _i32(payload, 3);
  var lon = _i32(payload, 7);
  final pts = <(double, double)>[(lat / 1e7, lon / 1e7)];
  for (var i = 1; i < count; i++) {
    final off = 11 + (i - 1) * 4;
    lat += _i16(payload, off) * 100;
    lon += _i16(payload, off + 2) * 100;
    pts.add((lat / 1e7, lon / 1e7));
  }
  return (f[2], zoom, count, pts);
}

void main() {
  group('frame header', () {
    test('0xAA 0x55 magic + little-endian payload length', () {
      final f = buildMapClockFrame(hour: 14, minute: 30);
      expect(f[0], 0xAA);
      expect(f[1], 0x55);
      expect(f[2], mapTypeClock);
      expect(f[3], 2); // lenL
      expect(f[4], 0); // lenH
      expect(f.length, 5 + 2);
    });
  });

  group('buildMapClockFrame', () {
    test('encodes hour/minute', () {
      final f = buildMapClockFrame(hour: 7, minute: 17);
      expect(f[5], 7);
      expect(f[6], 17);
    });
  });

  group('buildMapPosFrame', () {
    test('lat/lon x1e7 + spd/hdg/sl byte layout', () {
      final f = buildMapPosFrame(
        lat: 10.771800,
        lon: 106.698200,
        spd: 34,
        hdg: 312,
        speedLimit: 50,
      );
      expect(f[2], mapTypePos);
      expect(f.length, 5 + 12);
      // Payload: lat(i32) lon(i32) spd(u8) hdg(u16) sl(u8)
      expect(_i32(f, 5), 107718000); // 10.7718 * 1e7
      expect(_i32(f, 9), 1066982000); // 106.6982 * 1e7
      expect(f[13], 34);
      expect(_u16(f, 14), 312);
      expect(f[16], 50);
    });
  });

  group('buildMapNavFrame', () {
    test('dist + maneuver id + UTF-8 street', () {
      const street = 'Vườn Lài';
      final f = buildMapNavFrame(
        dist: 141,
        maneuverId: mapManeuverLeft,
        street: street,
      );
      expect(f[2], mapTypeNav);
      expect(_u16(f, 5), 141);
      expect(f[7], mapManeuverLeft);
      final tb = utf8.encode(street);
      expect(f[8], tb.length);
      expect(f.length, 5 + 4 + tb.length);
      for (var i = 0; i < tb.length; i++) {
        expect(f[9 + i], tb[i]);
      }
    });

    test('street is truncated to the firmware buffer (63 bytes)', () {
      final f = buildMapNavFrame(
        dist: 10,
        maneuverId: mapManeuverStraight,
        street: 'x' * 200,
      );
      expect(f[8], mapMaxStreetBytes - 1);
      expect(f.length, 5 + 4 + (mapMaxStreetBytes - 1));
    });
  });

  group('buildMapEtaFrame', () {
    test('hour/minute + arrive address', () {
      const arrive = '1A Nguyen Hue';
      final f = buildMapEtaFrame(hour: 14, minute: 32, arrive: arrive);
      expect(f[2], mapTypeEta);
      expect(f[5], 14);
      expect(f[6], 32);
      final tb = utf8.encode(arrive);
      expect(f[7], tb.length);
      expect(f.length, 5 + 3 + tb.length);
      for (var i = 0; i < tb.length; i++) {
        expect(f[8 + i], tb[i]);
      }
    });
  });

  group('buildMapRouteFrame', () {
    test('round-trips points through the firmware decoder', () {
      final pts = [
        const LatLng(10.771800, 106.698200),
        const LatLng(10.773200, 106.704000),
        const LatLng(10.769400, 106.701800),
      ];
      final f = buildMapRouteFrame(pts);
      final (type, zoom, count, decoded) = _decodeRoute(f);
      expect(type, mapTypeRoute);
      expect(zoom, 15);
      expect(count, 3);
      for (var i = 0; i < pts.length; i++) {
        expect(decoded[i].$1, closeTo(pts[i].latitude, 1e-5));
        expect(decoded[i].$2, closeTo(pts[i].longitude, 1e-5));
      }
    });

    test('long route decimates to 512 points (NAV_MAX_ROUTE_POINTS)', () {
      final pts = List.generate(
        600,
        (i) => LatLng(10.77 + i * 0.0001, 106.69 + i * 0.0001),
      );
      final f = buildMapRouteFrame(pts);
      final (_, _, count, _) = _decodeRoute(f);
      expect(count, 512);
      expect(f.length, 5 + 3 + 8 + (512 - 1) * 4);
    });

    test('single point is padded to the 2-point minimum', () {
      final f = buildMapRouteFrame([const LatLng(10.77, 106.69)]);
      final (_, _, count, _) = _decodeRoute(f);
      expect(count, 2);
    });
  });

  group('mapManeuverIdForIcon', () {
    test('maps clock icon codes to the board maneuver vocabulary', () {
      expect(mapManeuverIdForIcon(iconStraight), mapManeuverStraight);
      expect(mapManeuverIdForIcon(iconTurnLeft), mapManeuverLeft);
      expect(mapManeuverIdForIcon(iconTurnRight), mapManeuverRight);
      expect(mapManeuverIdForIcon(iconSlightLeft), mapManeuverSlightLeft);
      expect(mapManeuverIdForIcon(iconSlightRight), mapManeuverSlightRight);
      expect(mapManeuverIdForIcon(iconUturnLeft), mapManeuverUturn);
      expect(mapManeuverIdForIcon(iconUturnRight), mapManeuverUturn);
      expect(mapManeuverIdForIcon(iconRoundabout), mapManeuverRoundabout);
      expect(mapManeuverIdForIcon(iconArrive), mapManeuverArrive);
      expect(mapManeuverIdForIcon(iconUnknown), mapManeuverStraight);
    });
  });
}
