// WHERE does the app's built-up verdict change along QL20?
//
// The rate metrics (86.4 % of towns, 99.1 % of open country) say the rule is
// right ON AVERAGE. What a driver feels is the TRANSITION: "in town" starting
// kilometres before the town (which caps a mô tô at 50 where the law says 60),
// or "out of town" arriving while still inside it (the opposite error). So this
// walks the QL20 corridor end to end and prints every change of verdict with
// its chainage and its distance to the nearest OSM town, so each one can be
// judged on the spot.
//
// The fixtures come from `data/tmp/an_ql20_towns.py` — OSM place nodes and a
// hand-built centreline, NOT the app. The verdict is the app's REAL rule
// (`isUrbanArea` → `segmentDensity` / `poiDensity`), not a mirror of it.
//
//   flutter test test/func/resident/_ql20_sweep_test.dart            (both)
//   flutter test test/func/resident/_ql20_sweep_test.dart --plain-name "verdict at"
//
// Part 1 checks the IN verdict at every town on the corridor (a missed town
// posts the RURAL table inside a town). Part 2 prints the transitions.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/urban_area.dart';

const _townsPath = 'test/data/ql20_towns.json';
const _corridorPath = 'test/data/ql20_corridor.json';

/// Metres between [p] and a place node (flat approximation, fine at 11° N).
double _distM(LatLng p, num lat, num lng) {
  final dy = (p.latitude - lat) * 111000.0;
  final dx = (p.longitude - lng) * 109000.0;
  return math.sqrt(dy * dy + dx * dx);
}

String _nearestTown(List<Map<String, dynamic>> towns, LatLng p) {
  var best = '?';
  var bestD = double.infinity;
  for (final t in towns) {
    final d = _distM(p, t['lat'] as num, t['lng'] as num);
    if (d < bestD) {
      bestD = d;
      best = '${t['name']} ${bestD.round()}m';
    }
  }
  return best;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the in/out verdict at each QL20 town (the IN side)', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped('speed-limit assets are stubs here');
      return;
    }
    final towns = (jsonDecode(File(_townsPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(towns.length, greaterThanOrEqualTo(8),
        reason: 'the QL20 corridor should yield 8+ OSM towns');

    final missed = <String>[];
    // ignore: avoid_print
    print('QL20 towns — the app\'s built-up verdict where it decides the limit '
        '(rule: $kUrbanSegMin seg or $kUrbanPoiMin poi within '
        '${kUrbanRadiusM ~/ 1000} km)');
    // ignore: avoid_print
    print('  ${'town'.padRight(16)}${'type'.padRight(6)}'
        '${'seg'.padLeft(5)}${'poi'.padLeft(6)}${'off'.padLeft(7)}  verdict');
    for (final t in towns) {
      final p = LatLng((t['lat'] as num).toDouble(),
          (t['lng'] as num).toDouble());
      final seg = await segmentDensity(p);
      final poi = await poiDensity(p);
      final urban = await isUrbanArea(p);
      if (!urban) {
        missed.add('${t['name']} (${t['lat']},${t['lng']}, '
            '${t['offM']}m off the centreline)');
      }
      // ignore: avoid_print
      print('  ${(t['name'] as String).padRight(16)}'
          '${(t['place'] as String).padRight(6)}'
          '${seg.toString().padLeft(5)}${poi.toString().padLeft(6)}'
          '${'${t['offM']}m'.padLeft(7)}  '
          '${urban ? 'IN TOWN' : '>>> OUT (missed)'}');
    }
    // ignore: avoid_print
    print('  => ${towns.length - missed.length}/${towns.length} called IN');
    // A QL20 town sits on the densest road in the province, so the 187
    // country-wide misses (all 0seg/0poi communes — a data gap) must not reach
    // here: a missed town means the RURAL table inside a town.
    expect(missed, isEmpty, reason: 'missed on QL20: ${missed.join(' | ')}');
  });

  test('the in/out TRANSITIONS along the whole corridor (the OUT side)',
      () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped('speed-limit assets are stubs here');
      return;
    }
    final towns = (jsonDecode(File(_townsPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final corridor = (jsonDecode(File(_corridorPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

    bool? prev;
    var transitions = 0;
    var inPoints = 0;
    // ignore: avoid_print
    print('QL20 corridor sweep — ${corridor.length} points over '
        '${corridor.last['km']} km');
    for (final c in corridor) {
      final p = LatLng((c['lat'] as num).toDouble(),
          (c['lng'] as num).toDouble());
      final urban = await isUrbanArea(p);
      if (urban) inPoints++;
      if (prev != null && urban != prev) {
        transitions++;
        final seg = await segmentDensity(p);
        // ignore: avoid_print
        print('  ${(c['km'] as num).toStringAsFixed(1).padLeft(6)} km  '
            '${urban ? 'OUT -> IN ' : 'IN -> OUT'}  '
            'seg=${seg.toString().padLeft(5)}  '
            'near ${_nearestTown(towns, p)}');
      }
      prev = urban;
    }
    final pct = 100 * inPoints / corridor.length;
    // ignore: avoid_print
    print('  => $transitions changes; in-town on $inPoints/'
        '${corridor.length} points (${pct.toStringAsFixed(1)} %)');
    // The corridor passes through 12 towns; a handful of changes is expected.
    // ZERO would mean the whole highway is one verdict, which cannot be right.
    expect(transitions, greaterThan(3),
        reason: 'a 186 km corridor must cross several town boundaries');
  });
}
