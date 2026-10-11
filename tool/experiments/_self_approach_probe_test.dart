// PROBE: does any generated trip's geometry pass NEAR ITSELF? A nearest-vertex
// matcher cannot tell two legs apart when they are 20 m apart in space but 1 km
// apart along the route, and `_curIdx` is not monotonic (unlike `_curSeg`), so
// the match can jump to the other leg and the remaining distance jumps UP.
//
// Run: flutter test tool/experiments/_self_approach_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('self-approach pairs in the affected trips', () {
    const d = Distance();
    for (final id in ['mid_14', 'long_06', 'long_08', 'long_09', 'long_10',
                      'mid_01', 'short_01']) {
      final trip = jsonDecode(File('test/data/trips/$id.json').readAsStringSync())
          as Map<String, dynamic>;
      final geom = (trip['geometry'] as List)
          .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
          .toList();
      final cum = <double>[0];
      for (var i = 1; i < geom.length; i++) {
        cum.add(cum[i - 1] + d.as(LengthUnit.Meter, geom[i - 1], geom[i]));
      }
      // Coarse grid to avoid O(n^2) over 4,000 vertices.
      const cell = 0.003; // ~330 m
      final grid = <String, List<int>>{};
      String key(double lat, double lng) =>
          '${(lat / cell).floor()}:${(lng / cell).floor()}';
      for (var i = 0; i < geom.length; i++) {
        grid.putIfAbsent(key(geom[i].latitude, geom[i].longitude), () => []).add(i);
      }
      var pairs = 0;
      var worst = '';
      var worstGap = 0.0;
      for (var i = 0; i < geom.length; i++) {
        final ci = (geom[i].latitude / cell).floor();
        final cj = (geom[i].longitude / cell).floor();
        for (var a = -1; a <= 1; a++) {
          for (var b = -1; b <= 1; b++) {
            for (final j in grid['${ci + a}:${cj + b}'] ?? const <int>[]) {
              if (j <= i) continue;
              final gap = cum[j] - cum[i];
              if (gap < 400) continue; // same stretch, not a self-approach
              final m = d.as(LengthUnit.Meter, geom[i], geom[j]);
              if (m > 45) continue; // not close enough to confuse the match
              pairs++;
              if (gap > worstGap) {
                worstGap = gap;
                worst = 'vertices $i and $j are ${m.toStringAsFixed(1)} m apart '
                    'in space but ${gap.round()} m apart along the route';
              }
            }
          }
        }
      }
      // ignore: avoid_print
      print('  $id (${geom.length} v, ${cum.last.round()} m): '
          '$pairs self-approach pair(s)'
          '${worst.isEmpty ? '' : ' — worst: $worst'}');
    }
  });
}
