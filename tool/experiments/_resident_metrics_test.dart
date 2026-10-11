// EXPERIMENT (not part of the gate — see tool/check.sh): accuracy / recall /
// precision of the built-up ("khu đông dân cư") rule over EVERY populated place
// in Vietnam, not the 1,375-town sample the suite asserts against.
//
// Run: flutter test tool/experiments/_resident_metrics_test.dart
//
// Labels come from the shipped extract (tool/scan_vn_places.py →
// test/data/vn_places_all.json):
//   positive  place=city|town           the driver IS in a built-up area
//   negative  everything else           village / hamlet / suburb / quarter / …
//
// The negative class is reported BOTH ways, because it is genuinely arguable:
// a village strung along a highway is a "khu dân cư" by the road law (you must
// slow down), so a "false positive" there is arguably the rule being right. The
// metric that can actually hurt the driver is RECALL — missing a city/town
// means showing the rural limit inside a town.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/urban_area.dart';

/// Settlement types that are the built-up truth.
const _builtUp = {'city', 'town'};

/// OSM place types that are URBAN by definition — a neighbourhood, a quarter,
/// a suburb and a city block are inside a town, so a rule that calls them
/// built-up is right. This is the honest positive class for a point rule.
const _urban = {
  'city', 'town', 'suburb', 'neighbourhood', 'quarter', 'city_block',
};

/// Settlement types that are RURAL: a village or a hamlet has houses along its
/// road (so a driver SHOULD slow there — that is why the rule fires on 77% of
/// them and that is not an error), while an isolated dwelling or a bare
/// `locality` is not a built-up area at all.
const _ruralSettlement = {
  'village', 'hamlet', 'isolated_dwelling', 'locality', 'commune',
};

void p(String s) {
  // ignore: avoid_print
  print(s);
}

/// Accuracy / precision / recall / specificity / F1 from a 2x2 table.
Map<String, double> metrics(int tp, int fn, int fp, int tn) {
  final total = tp + fn + fp + tn;
  final recall = (tp + fn) == 0 ? double.nan : tp / (tp + fn);
  final precision = (tp + fp) == 0 ? double.nan : tp / (tp + fp);
  final specificity = (tn + fp) == 0 ? double.nan : tn / (tn + fp);
  final accuracy = total == 0 ? double.nan : (tp + tn) / total;
  final f1 = (precision + recall) == 0 || precision.isNaN || recall.isNaN
      ? double.nan
      : 2 * precision * recall / (precision + recall);
  return {
    'accuracy': accuracy,
    'precision': precision,
    'recall': recall,
    'specificity': specificity,
    'f1': f1,
  };
}

String pct(double v) =>
    v.isNaN ? '  n/a' : '${(v * 100).toStringAsFixed(1)}%'.padLeft(6);

String table(String label, int tp, int fn, int fp, int tn) {
  final m = metrics(tp, fn, fp, tn);
  return '$label\n'
      '    TP $tp   FN $fn   FP $fp   TN $tn\n'
      '    accuracy ${pct(m['accuracy']!)}   precision ${pct(m['precision']!)}'
      '   recall ${pct(m['recall']!)}   specificity ${pct(m['specificity']!)}'
      '   F1 ${pct(m['f1']!)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('confusion matrix over every populated place in Vietnam', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped('packs are stubs here (see tool/stub_assets.sh)');
      return;
    }
    final places = (jsonDecode(
            File('test/data/vn_places_all.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    p('populated places in the scan: ${places.length}');

    // per place type → [called built-up, total]
    final byType = <String, List<int>>{};
    final t0 = DateTime.now();
    for (final e in places) {
      final type = (e['place'] as String?) ?? '?';
      final hit = await isUrbanArea(
          LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble()));
      final row = byType.putIfAbsent(type, () => [0, 0]);
      row[0] += hit ? 1 : 0;
      row[1] += 1;
    }
    final secs = DateTime.now().difference(t0).inMilliseconds / 1000.0;
    p('scanned in ${secs.toStringAsFixed(1)} s '
        '(${(places.length / secs).round()} lookups/s)\n');

    p('called built-up, by OSM place type:');
    final types = byType.keys.toList()..sort();
    for (final t in types) {
      final (hit, total) = (byType[t]![0], byType[t]![1]);
      final rate = total == 0 ? 0.0 : hit / total;
      p('  ${t.padRight(18)} ${hit.toString().padLeft(6)} / '
          '${total.toString().padLeft(6)}  ${(rate * 100).toStringAsFixed(1)}%');
    }
    p('');

    // ---- variant A: city/town only, against the rural settlemon types ----
    var tpA = 0, fnA = 0, fpA = 0, tnA = 0;    // ---- variant B: every URBAN type (town + suburb + quarter + …) ----
    var tpB = 0, fnB = 0, fpB = 0, tnB = 0;
    for (final t in types) {
      final hit = byType[t]![0], total = byType[t]![1], miss = total - hit;
      if (_builtUp.contains(t)) {
        tpA += hit; fnA += miss;
      } else if (_ruralSettlement.contains(t)) {
        fpA += hit; tnA += miss;
      }
      if (_urban.contains(t)) {
        tpB += hit; fnB += miss;
      } else if (_ruralSettlement.contains(t)) {
        fpB += hit; tnB += miss;
      }
    }
    p(table('A) truth = CITY/TOWN only, vs village/hamlet/isolated/locality',
        tpA, fnA, fpA, tnA));
    p('');
    p(table('B) truth = every URBAN type (+suburb, quarter, neighbourhood,\n'
        '   city_block), vs village/hamlet/isolated/locality', tpB, fnB, fpB, tnB));
    p('');

    // ---- the matrix that answers the DRIVER's question ----
    // What the app is asked is not "is this place a town" but "is this POINT
    // on a road inside a built-up area", and the two classes that matter are
    // the towns (say 50 where 50 is right) and open country (leave it at 60).
    // Density is the expensive part and is reused by the sweep below.
    final townDens = <(int, int)>[];
    for (final e in places) {
      if (!_builtUp.contains(e['place'])) continue;
      final pos =
          LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble());
      townDens.add((await segmentDensity(pos), await poiDensity(pos)));
    }
    final ruralPoints = (jsonDecode(
            File('test/data/vn_rural_osm.json').readAsStringSync()) as List)
        .cast<List<dynamic>>();
    final ruralDens = <(int, int)>[];
    for (final r in ruralPoints) {
      final pos = LatLng((r[0] as num).toDouble(), (r[1] as num).toDouble());
      ruralDens.add((await segmentDensity(pos), await poiDensity(pos)));
    }
    bool fires((int, int) d) => d.$1 >= kUrbanSegMin || d.$2 >= kUrbanPoiMin;
    final mTp = townDens.where(fires).length;
    final mFp = ruralDens.where(fires).length;
    p(table('the app\'s task: POINT in a built-up area — ${townDens.length} '
        'cities/towns vs ${ruralDens.length} open-country points\n'
        '   (current rule: >= $kUrbanSegMin segments OR >= $kUrbanPoiMin POIs '
        'within ${kUrbanRadiusM ~/ 1000} km)',
        mTp, townDens.length - mTp, mFp, ruralDens.length - mFp));
    p('');

    // ---- what the driver actually receives, as limits ----
    final townMisses = <String>[];
    for (final e in places) {
      if (!_builtUp.contains(e['place'])) continue;
      final pos =
          LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble());
      if (!await isUrbanArea(pos)) {
        townMisses.add('${e['name']}');
      }
    }
    p('cities/towns the rule misses entirely: ${townMisses.length} of '
        '${byType['city']![1] + byType['town']![1]}');
    if (townMisses.isNotEmpty) {
      p('  ${townMisses.take(12).join(', ')} …');
    }

    // WHY they are missed decides whether anything can be done about it:
    //  * no pack data at all (0 segments AND 0 POIs) -> a data-coverage gap in
    //    the Waze/POI packs, which no threshold can fix
    //  * density just under the threshold -> the threshold is too high
    var noData = 0, nearMiss = 0;
    final near = <String>[];
    for (final e in places) {
      if (!_builtUp.contains(e['place'])) continue;
      final pos =
          LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble());
      if (await isUrbanArea(pos)) continue;
      final seg = await segmentDensity(pos);
      final poi = await poiDensity(pos);
      if (seg == 0 && poi == 0) {
        noData++;
      } else if (seg < kUrbanSegMin * 2 && poi < kUrbanPoiMin * 2) {
        nearMiss++;
        near.add('${e['name']}(${seg}seg/${poi}poi)');
      }
    }
    p('  why: $noData have NO pack data at all (0 segments, 0 POIs) — a coverage'
        ' gap, not a threshold one');
    p('       $nearMiss are near misses (within 2x of the threshold '
        '$kUrbanSegMin seg / $kUrbanPoiMin poi)');
    if (near.isNotEmpty) {
      p('       ${near.take(20).join(', ')}');
    }

    // ---- the same rule, on the SAMPLE the test suite asserts against ----
    final fixture = (jsonDecode(
            File('test/data/vn_urban_osm.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    var fxHit = 0;
    for (final e in fixture) {
      if (await isUrbanArea(
          LatLng((e['lat'] as num).toDouble(), (e['lng'] as num).toDouble()))) {
        fxHit++;
      }
    }
    p('');
    p('the suite\'s fixture (test/data/vn_urban_osm.json): '
        '${fixture.length} towns, $fxHit called built-up '
        '(${(100 * fxHit / fixture.length).toStringAsFixed(1)}%)');
    p('  vs the full population: '
        '${byType['city']![0] + byType['town']![0]} / '
        '${byType['city']![1] + byType['town']![1]} '
        '(${(100 * (byType['city']![0] + byType['town']![0]) / (byType['city']![1] + byType['town']![1])).toStringAsFixed(1)}%)');

    // ---- the false positive that actually costs the driver ----
    // Not a village (slowing in a village is correct) but OPEN COUNTRY: a
    // 2-way rural road shown at the in-town 50 instead of 60.
    final rural = (jsonDecode(
            File('test/data/vn_rural_osm.json').readAsStringSync()) as List)
        .cast<List<dynamic>>();
    var ruralHit = 0;
    for (final r in rural) {
      if (await isUrbanArea(
          LatLng((r[0] as num).toDouble(), (r[1] as num).toDouble()))) {
        ruralHit++;
      }
    }
    p('');
    p('open country (test/data/vn_rural_osm.json, >=12 km from any town, '
        '>=1 km off a major road):');
    p('  ${rural.length} points, $ruralHit called built-up '
        '(${(100 * ruralHit / rural.length).toStringAsFixed(2)}% false alarms) '
        '-> of the points the rule calls built-up in open country, the limit\n'
        '     is capped at the in-town table where 60 was legal');

    // ---- the threshold, as a trade-off rather than an opinion ----
    // The rule is `segments >= kUrbanSegMin || POIs >= kUrbanPoiMin` inside
    // 2 km. Density is the expensive part and it is already computed, so the
    // whole sweep is arithmetic — and it says what a threshold change buys.
    p('');
    p('threshold sweep (recall on all 1,811 cities/towns vs false alarms on '
        'the 882 open-country points; current = ${kUrbanSegMin}seg/'
        '${kUrbanPoiMin}poi):');
    p('  segMin poiMin    recall   open-country false alarms   (misses)');
    for (final segMin in [1, 2, 3, 5, 7, 10, 12, 15]) {
      for (final poiMin in [1, 2, 5, 8, 12, 25]) {
        final townHit = townDens.where((d) => d.$1 >= segMin || d.$2 >= poiMin)
            .length;
        final ruralFp =
            ruralDens.where((d) => d.$1 >= segMin || d.$2 >= poiMin).length;
        final recall = townHit / townDens.length;
        final fp = ruralFp / ruralDens.length;
        final now = (segMin == kUrbanSegMin && poiMin == kUrbanPoiMin);
        p('  ${segMin.toString().padLeft(5)} ${poiMin.toString().padLeft(6)}'
            '   ${pct(recall)}   ${pct(fp).padLeft(10)}'
            '   (${townDens.length - townHit})${now ? '   <- current' : ''}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
