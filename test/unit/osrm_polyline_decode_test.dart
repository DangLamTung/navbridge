/// Does the app decode an OSRM polyline to the SAME points the JSON says?
///
/// The simulation feeds the app a route planned elsewhere (tool/sim_track.py),
/// so the decoder is the seam between the two. A mismatch there is silent and
/// catastrophic: the run drove 2.74 km of geometry but reported its destination
/// as `2791739.5,3264281.8`, and the drive died without an error
/// (2026-10-08).
///
///   flutter test test/unit/osrm_polyline_decode_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/services/osrm.dart';

void main() {
  test('a served OSRM route decodes to the coordinates it also lists', () {
    final f = File('build/web/routes/sim_route.json');
    if (!f.existsSync()) {
      markTestSkipped(
        'no served route to check (run tool/sim_track.py to write one)',
      );
      return;
    }
    final doc = jsonDecode(f.readAsStringSync());
    final r = (doc['routes'] as List).first as Map<String, dynamic>;
    final pts = decodePolyline(r['geometry'] as String);

    // The manoeuvre locations are the same coordinates, in plain numbers.
    final steps = <Map<String, dynamic>>[];
    for (final leg in (r['legs'] as List).cast<Map<String, dynamic>>()) {
      steps.addAll((leg['steps'] as List).cast<Map<String, dynamic>>());
    }
    final firstLoc =
        ((steps.first['maneuver'] as Map)['location'] as List).cast<num>();
    final lastLoc =
        ((steps.last['maneuver'] as Map)['location'] as List).cast<num>();

    expect(pts, isNotEmpty, reason: 'the polyline must decode at all');
    // OSRM gives [lng, lat]; LatLng takes (lat, lng).
    expect(pts.first.latitude, closeTo(firstLoc[1].toDouble(), 1e-4),
        reason: 'first point');
    expect(pts.first.longitude, closeTo(firstLoc[0].toDouble(), 1e-4));
    // The last geometry point IS the destination — this is the one that was
    // wrong, and a wrong destination is what killed the drive.
    expect(pts.last.latitude, closeTo(lastLoc[1].toDouble(), 1e-4),
        reason: 'last point (the destination)');
    expect(pts.last.longitude, closeTo(lastLoc[0].toDouble(), 1e-4));
    // Every point must be a plausible Vietnam coordinate, not accumulated
    // garbage from a misread varint.
    for (final p in pts) {
      expect(p.latitude.abs(), lessThan(30),
          reason: 'a latitude of ${p.latitude} means the decoder drifted');
      expect(p.longitude.abs(), lessThan(130));
    }
  });
}
