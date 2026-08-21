/// Export a planned route to the common planning formats:
///
///  - **GPX 1.1** (the universal GPS "planning thing" — Garmin, OSMAnd,
///    Komoot, GaiaGPS…) with `<wpt>` placemarks for every stop, an `<rte>`
///    (ordered stops, what turn-by-turn units follow) and a `<trk>`
///    (the full driven polyline).
///  - **KML 2.2** (Google Earth / Google Maps "My Maps") as a styled
///    `LineString` plus a `Point` Placemark per stop.
///  - **KMZ** = the KML zipped (Google Earth's own format).
///
/// The string builders are pure (unit-testable); the only I/O helpers write
/// the files under `<documents>/plans` ready for the share sheet.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'package:navbridge/core/trip_plan.dart';

const String _gpxNs = 'http://www.topografix.com/GPX/1/1';
const String _kmlNs = 'http://www.opengis.net/kml/2.2';

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _coord(double v) => v.toStringAsFixed(7);

/// Sanitize [name] into a safe file name (keeps Vietnamese letters).
String sanitizeFileName(String name) => name
    .replaceAll(RegExp(r'[^\p{L}\p{N} _-]+', unicode: true), '_')
    .replaceAll(RegExp(r'\s+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '')
    .trim();

/// Build a GPX 1.1 document for a planned route.
///
/// [stops] is the ordered stop list (origin first, destination last);
/// [geometry] is the full route polyline.
String gpxFromRoute({
  required String name,
  required List<LatLng> geometry,
  required List<TripStop> stops,
}) {
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  b.writeln('<gpx version="1.1" creator="NavBridge" xmlns="$_gpxNs">');
  b.writeln('  <metadata>');
  b.writeln('    <name>${_xmlEscape(name)}</name>');
  b.writeln('    <time>${DateTime.now().toUtc().toIso8601String()}</time>');
  b.writeln('  </metadata>');
  // Waypoints for each stop.
  for (var i = 0; i < stops.length; i++) {
    final s = stops[i];
    final role = i == 0
        ? 'Điểm xuất phát'
        : i == stops.length - 1
        ? 'Điểm đến'
        : 'Điểm dừng $i';
    b.writeln('  <wpt lat="${_coord(s.lat)}" lon="${_coord(s.lng)}">');
    b.writeln('    <name>${_xmlEscape(s.name.isEmpty ? role : s.name)}</name>');
    b.writeln('    <cmt>${_xmlEscape(role)}</cmt>');
    b.writeln('  </wpt>');
  }
  // Route = the ordered stops (turn-by-turn devices follow this).
  b.writeln('  <rte>');
  b.writeln('    <name>${_xmlEscape(name)}</name>');
  for (final s in stops) {
    b.writeln('    <rtept lat="${_coord(s.lat)}" lon="${_coord(s.lng)}">');
    b.writeln('      <name>${_xmlEscape(s.name)}</name>');
    b.writeln('    </rtept>');
  }
  b.writeln('  </rte>');
  // Track = the full polyline.
  b.writeln('  <trk>');
  b.writeln('    <name>${_xmlEscape(name)}</name>');
  b.writeln('    <trkseg>');
  for (final p in geometry) {
    b.writeln(
      '      <trkpt lat="${_coord(p.latitude)}" '
      'lon="${_coord(p.longitude)}"/>',
    );
  }
  b.writeln('    </trkseg>');
  b.writeln('  </trk>');
  b.writeln('</gpx>');
  return b.toString();
}

/// Build a KML 2.2 document (Google Earth / My Maps) for a planned route.
String kmlFromRoute({
  required String name,
  required List<LatLng> geometry,
  required List<TripStop> stops,
}) {
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  b.writeln('<kml xmlns="$_kmlNs">');
  b.writeln('  <Document>');
  b.writeln('    <name>${_xmlEscape(name)}</name>');
  b.writeln('    <open>1</open>');
  b.writeln('    <Style id="routeLine">');
  b.writeln('      <LineStyle>');
  b.writeln('        <color>ff1a73e8</color>');
  b.writeln('        <width>5</width>');
  b.writeln('      </LineStyle>');
  b.writeln('    </Style>');
  // The route line.
  b.writeln('    <Placemark>');
  b.writeln('      <name>${_xmlEscape(name)}</name>');
  b.writeln('      <styleUrl>#routeLine</styleUrl>');
  b.writeln('      <LineString>');
  b.writeln('        <tessellate>1</tessellate>');
  b.writeln('        <coordinates>');
  for (final p in geometry) {
    b.writeln('          ${_coord(p.longitude)},${_coord(p.latitude)},0');
  }
  b.writeln('        </coordinates>');
  b.writeln('      </LineString>');
  b.writeln('    </Placemark>');
  // A Point per stop.
  for (var i = 0; i < stops.length; i++) {
    final s = stops[i];
    final role = i == 0
        ? 'Điểm xuất phát'
        : i == stops.length - 1
        ? 'Điểm đến'
        : 'Điểm dừng $i';
    b.writeln('    <Placemark>');
    b.writeln(
      '      <name>${_xmlEscape(s.name.isEmpty ? role : s.name)}</name>',
    );
    b.writeln('      <description>${_xmlEscape(role)}</description>');
    b.writeln('      <Point>');
    b.writeln(
      '        <coordinates>${_coord(s.lng)},${_coord(s.lat)},0'
      '</coordinates>',
    );
    b.writeln('      </Point>');
    b.writeln('    </Placemark>');
  }
  b.writeln('  </Document>');
  b.writeln('</kml>');
  return b.toString();
}

/// Wrap [kml] in a ZIP archive ([baseName] is the .kml file name inside) —
/// this is the KMZ format Google Earth opens.
Uint8List kmzFromKml(String kml, String baseName) {
  final bytes = utf8.encode(kml);
  final arc = Archive()
    ..addFile(ArchiveFile('$baseName.kml', bytes.length, bytes));
  return ZipEncoder().encodeBytes(arc);
}

/// Directory where route exports are written before sharing.
Future<Directory> plansDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/plans');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Write [bytes] as `<baseName>.<extension>` under `<documents>/plans`;
/// returns the file.
Future<File> writeRouteExport(
  String baseName,
  String extension,
  List<int> bytes,
) async {
  final dir = await plansDirectory();
  final f = File('${dir.path}/$baseName.$extension');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}
