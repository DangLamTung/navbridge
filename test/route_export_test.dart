import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/services/route_export.dart';

void main() {
  final stops = [
    TripStop(name: 'Nhà riêng', lat: 10.8231, lng: 106.6297),
    TripStop(name: 'Sân bay', lat: 10.8188, lng: 106.6520),
  ];
  final geometry = [
    const LatLng(10.8231, 106.6297),
    const LatLng(10.8209, 106.6342),
    const LatLng(10.8188, 106.6520),
  ];

  group('GPX', () {
    test('valid 1.1 root with metadata', () {
      final gpx = gpxFromRoute(
        name: 'Tuyến A → B',
        geometry: geometry,
        stops: stops,
      );
      expect(gpx, contains('<gpx version="1.1"'));
      expect(gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(gpx, contains('<metadata>'));
      expect(gpx, contains('<name>Tuyến A → B</name>'));
    });

    test('escapes XML special chars in names', () {
      final gpx = gpxFromRoute(
        name: 'A & B <C>',
        geometry: geometry,
        stops: [TripStop(name: 'N <1> & "2"', lat: 1, lng: 2)],
      );
      expect(gpx, isNot(contains('<name>A & B')));
      expect(gpx, contains('A &amp; B &lt;C&gt;'));
      expect(gpx, contains('N &lt;1&gt; &amp; &quot;2&quot;'));
    });

    test('wpt + rtept for each stop, trkpt for every geometry point', () {
      final gpx = gpxFromRoute(name: 'T', geometry: geometry, stops: stops);
      expect(RegExp('<wpt ').allMatches(gpx).length, 2);
      expect(RegExp('<rtept ').allMatches(gpx).length, 2);
      expect(RegExp('<trkpt ').allMatches(gpx).length, geometry.length);
      expect(gpx, contains('<rte>'));
      expect(gpx, contains('<trk>'));
      expect(gpx, contains('<trkseg>'));
      // Coordinates are written with 7 decimals.
      expect(gpx, contains('106.6297000'));
    });

    test('stop roles (start/destination)', () {
      final gpx = gpxFromRoute(name: 'T', geometry: geometry, stops: stops);
      expect(gpx, contains('Điểm xuất phát'));
      expect(gpx, contains('Điểm đến'));
    });
  });

  group('KML', () {
    test('valid 2.2 root + LineString with all points', () {
      final kml = kmlFromRoute(
        name: 'Tuyến A → B',
        geometry: geometry,
        stops: stops,
      );
      expect(kml, contains('xmlns="http://www.opengis.net/kml/2.2"'));
      expect(kml, contains('<LineString>'));
      // Coordinates are "lon,lat" — check the first geometry point.
      expect(kml, contains('106.6297000,10.8231000,0'));
      expect(RegExp('<Placemark').allMatches(kml).length, 1 + stops.length);
      expect(RegExp('<Point>').allMatches(kml).length, stops.length);
      expect(kml, contains('<Style id="routeLine">'));
    });
  });

  group('KMZ', () {
    test('kmzFromKml zips a readable KML', () {
      final kml = kmlFromRoute(
        name: 'Tuyến A → B',
        geometry: geometry,
        stops: stops,
      );
      final kmz = kmzFromKml(kml, 'tuyen');
      expect(kmz.length, greaterThan(0));
      final arc = ZipDecoder().decodeBytes(kmz);
      expect(arc.length, 1);
      final content = utf8.decode(arc.first.content as List<int>);
      expect(content, contains('<kml'));
      expect(content, contains('<LineString>'));
    });
  });

  group('sanitizeFileName', () {
    test('keeps Vietnamese + safe chars, strips the rest', () {
      expect(sanitizeFileName('Nhà riêng → Sân bay!!'), 'Nhà_riêng_Sân_bay');
      expect(sanitizeFileName('A/B\\C:d'), 'A_B_C_d');
      expect(sanitizeFileName('   '), '');
    });
  });
}
