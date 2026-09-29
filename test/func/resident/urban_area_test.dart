// GROUND-TRUTH test: is the "khu đông dân cư" (built-up area) rule right?
//
// The app answers in/out of a built-up area from POI DENSITY
// (`lib/services/urban_area.dart`: >= 25 POIs within 2 km of the bundled
// vietnam_pois.json), and that answer switches the statutory limit table
// (urban vs rural: a mô tô is 60 in town, 70 outside; a truck 50/60). So a
// wrong answer posts a wrong limit — this measures it against data that does
// NOT come from the app:
//
//   urban  every OSM `place=city|town` node in Vietnam (tool/fetch_osm_places.py)
//   rural  a grid of points across the country, kept only when >= 12 km from
//          any city/town and >= 4 km from any village/hamlet/suburb
//
// The point of the counts: a "correct" claim needs 100+ of each, not a demo.
//
//   flutter test test/func/resident/urban_area_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/urban_area.dart';

const _urbanPath = 'test/data/vn_urban_osm.json';
const _ruralPath = 'test/data/vn_rural_osm.json';

/// Floors from the measurement (2026-09-27), not aspirations:
///
///   towns 1 298/1 375 = 94.4 % called built-up (was 3.3 % with the POI rule
///   alone). The 77 misses have ZERO segments AND zero POIs — they are OSM
///   towns/communes the two packs simply do not cover ("Trường Sa" is the
///   Spratly Islands, "Tùng Vài"/"Bảo Lâm" are mountain communes), so the
///   remaining error is data availability, not the rule.
///   rural   855/882 = 96.9 % called open country. Most false alarms sit in the
///   Mekong Delta, where the countryside really is settled along every canal
///   (10.44,105.92 with 61 segments within 2 km is not open country).
///
/// These floors fail if the rule regresses; raise them when the packs improve.
const double _minUrbanRecall = 0.85;
const double _minRuralSpecificity = 0.985;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Sanity: the app's own knobs, printed so a threshold change is visible here.
  test('the rule is segment density >= $kUrbanSegMin or POI density >= $kUrbanPoiMin',
      () {
    expect(kUrbanSegMin, 10);
    expect(kUrbanPoiMin, 25);
    expect(kUrbanRadiusM, 2000);
  });

  test('in/out of a built-up area, against OSM (>=100 places each)', () async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped(
        'speed-limit assets are stubs here (see tool/stub_assets.sh)',
      );
      return;
    }
    final urban = (jsonDecode(File(_urbanPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final rural = (jsonDecode(File(_ruralPath).readAsStringSync()) as List)
        .map((e) => (e as List).cast<num>())
        .toList();

    expect(
      urban.length,
      greaterThanOrEqualTo(100),
      reason: 'need 100+ real towns to claim the logic is tested',
    );
    expect(
      rural.length,
      greaterThanOrEqualTo(100),
      reason: 'need 100+ real rural points',
    );

    // ---- towns: the rule must call them built-up ----
    var urbanHit = 0;
    final urbanMiss = <(String, LatLng, int, int)>[];
    for (final t in urban) {
      final p = LatLng((t['lat'] as num).toDouble(), (t['lng'] as num).toDouble());
      if (await isUrbanArea(p)) {
        urbanHit++;
      } else {
        urbanMiss.add((
          (t['name'] ?? '?') as String,
          p,
          await poiDensity(p),
          await segmentDensity(p),
        ));
      }
    }

    // ---- countryside: the rule must NOT call it built-up ----
    var ruralHit = 0;
    final ruralMiss = <(LatLng, int, int)>[];
    for (final r in rural) {
      final p = LatLng(r[0].toDouble(), r[1].toDouble());
      if (!await isUrbanArea(p)) {
        ruralHit++;
      } else {
        ruralMiss.add((p, await poiDensity(p), await segmentDensity(p)));
      }
    }

    final recall = urbanHit / urban.length;
    final specificity = ruralHit / rural.length;
    // ignore: avoid_print
    print(
      'built-up rule vs OSM — towns $urbanHit/${urban.length} '
      '(${(recall * 100).toStringAsFixed(1)}% called built-up, '
      '${urbanMiss.length} missed); rural $ruralHit/${rural.length} '
      '(${(specificity * 100).toStringAsFixed(1)}% called open country, '
      '${ruralMiss.length} false alarms)',
    );
    if (urbanMiss.isNotEmpty) {
      final worst = urbanMiss.toList()
        ..sort((a, b) => a.$4.compareTo(b.$4));
      final sample = worst
          .take(12)
          .map((m) => '${m.$1}=${m.$4}seg/${m.$3}poi')
          .join(', ');
      // ignore: avoid_print
      print('  lowest segment density among MISSED towns: $sample');
    }
    if (ruralMiss.isNotEmpty) {
      final sample = ruralMiss
          .take(12)
          .map((m) =>
              '${m.$1.latitude.toStringAsFixed(2)},${m.$1.longitude.toStringAsFixed(2)}='
              '${m.$3}seg/${m.$2}poi')
          .join(', ');
      // ignore: avoid_print
      print('  worst false alarms: $sample');
    }

    expect(
      recall,
      greaterThanOrEqualTo(_minUrbanRecall),
      reason: 'only ${(recall * 100).toStringAsFixed(1)}% of real towns are '
          'detected — the app then falls back to the RURAL limit inside town',
    );
    expect(
      specificity,
      greaterThanOrEqualTo(_minRuralSpecificity),
      reason: '${ruralMiss.length} open-country points are called built-up, '
          'which caps the limit at the urban table where the road is rural',
    );

    // ---- the gate itself: a POSTED limit always wins over the rule ----
    final hn = urban.firstWhere(
      (t) => ((t['name'] ?? '') as String).contains('H\u00e0 N\u1ed9i'),
      orElse: () => urban.first,
    );
    final hanoi = LatLng(
      (hn['lat'] as num).toDouble(),
      (hn['lng'] as num).toDouble(),
    );
    expect(await isUrbanArea(hanoi), isTrue);
    expect(await builtUpRuleApplies(hanoi, hasPosted: true), isFalse);
    expect(await builtUpRuleApplies(hanoi, hasPosted: false), isTrue);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
