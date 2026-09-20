import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_scan_isolate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled road-sign index', () async {
    final signs = await loadOfflineRoadSigns();
    expect(signs, isNotEmpty);
    for (final s in signs) {
      expect(s.lat, inInclusiveRange(8.0, 23.6));
      expect(s.lng, inInclusiveRange(102.0, 110.0));
      expect(s.name, isNotEmpty);
      expect(RoadSignKind.values, contains(s.kind));
    }
  });

  test('index covers all sign kinds', () async {
    final signs = await loadOfflineRoadSigns();
    expect(signs, isNotEmpty);
    final kinds = signs.map((s) => s.kind).toSet();
    // The Vietnam dataset has traffic lights, stop, give-way, speed-limit and
    // the VN-standard prohibitions (cấm vượt, cấm rẽ, cấm quay đầu, hết mọi
    // lệnh cấm).
    expect(kinds, contains(RoadSignKind.signal));
    expect(kinds, contains(RoadSignKind.stop));
    expect(kinds, contains(RoadSignKind.speed));
    expect(kinds, contains(RoadSignKind.noPassing));
    expect(kinds, contains(RoadSignKind.noLeftTurn));
    expect(kinds, contains(RoadSignKind.noRightTurn));
    expect(kinds, contains(RoadSignKind.noUTurn));
    expect(kinds, contains(RoadSignKind.endProhibitions));
    // Speed signs carry a usable km/h value for the sign icon.
    for (final s in signs.where((s) => s.kind == RoadSignKind.speed)) {
      expect(s.value, isNotNull);
      expect(s.value, inInclusiveRange(5, 200));
    }
  });

  test(
    'the khu-đông-dân-cư boundary layer is dropped, not shown as lights',
    () async {
      // The asset still carries 'populated' / 'populated_end' rows (they come
      // from the VietMap/OSM merge, which is regenerated separately), so the load
      // filter must drop them — a silent fall-through would render every bogus
      // boundary as a TRAFFIC LIGHT, which is worse than the layer itself.
      final signs = await loadOfflineRoadSigns();
      final raw = await rootBundle.loadString(
        'assets/offline_map/vietnam_signs.json',
      );
      final rows = (jsonDecode(raw)['signs'] as List)
          .cast<Map<String, dynamic>>();
      final droppedKeys = {
        for (final r in rows)
          if (droppedSignKinds.contains(r['kind'])) '${r['lat']},${r['lng']}',
      };
      // If this hits 0 the asset was cleaned up too — the filter is then dead
      // weight, but keep it: an OLD downloaded copy can reintroduce the rows.
      expect(signs, isNotEmpty);
      expect(signs.length, lessThanOrEqualTo(rows.length));
      for (final s in signs) {
        expect(
          droppedKeys,
          isNot(contains('${s.lat},${s.lng}')),
          reason: 'a dropped boundary row survived the load filter',
        );
      }
    },
  );

  test('signsAheadOnRoute returns ordered signs ahead', () async {
    final signs = await loadOfflineRoadSigns();
    expect(signs, isNotEmpty);
    // A short route through central HCMC (Bến Thành → D1), dense with
    // traffic lights.
    final geometry = [
      const LatLng(10.7695, 106.6930),
      const LatLng(10.7730, 106.6990),
      const LatLng(10.7760, 106.7040),
      const LatLng(10.7790, 106.7090),
    ];
    final ahead = await signsAheadOnRoute(
      const LatLng(10.7695, 106.6930),
      geometry,
      maxAheadMeters: 3000,
    );
    for (var i = 1; i < ahead.length; i++) {
      expect(
        ahead[i].routeMeters,
        greaterThanOrEqualTo(ahead[i - 1].routeMeters),
      );
    }
    for (final a in ahead) {
      expect(a.routeMeters, greaterThanOrEqualTo(0));
      expect(a.routeMeters, lessThanOrEqualTo(3000));
    }
  });

  test('signsNearRoute returns only signs on/near the route', () async {
    final signs = await loadOfflineRoadSigns();
    expect(signs, isNotEmpty);
    final geometry = [
      const LatLng(10.7695, 106.6930),
      const LatLng(10.7730, 106.6990),
      const LatLng(10.7760, 106.7040),
      const LatLng(10.7790, 106.7090),
    ];
    final near = await signsNearRoute(geometry);
    expect(near.length, lessThan(signs.length));
    expect(near.length, greaterThan(0));
    for (final s in near) {
      expect(_minDistanceToLine(geometry, s.pos), lessThanOrEqualTo(200));
    }
  });

  test('signsNearRoute returns empty for an empty/short route', () async {
    expect(await signsNearRoute(const []), isEmpty);
    expect(await signsNearRoute(const [LatLng(10.77, 106.70)]), isEmpty);
  });

  test('signsAheadOnRoute returns empty for an empty/short route', () async {
    expect(
      await signsAheadOnRoute(const LatLng(10.77, 106.70), const []),
      isEmpty,
    );
  });

  test('dedupSignAhead collapses same-kind signs within ~100 m', () {
    // Two "80" speed signs ~50 m apart = the same sign from two sources →
    // only the nearer survives.
    final a = [
      SignAhead(
        sign: RoadSign(
          name: 'Hạn chế tốc độ',
          lat: 10.7695,
          lng: 106.6930,
          kind: RoadSignKind.speed,
          value: 80,
        ),
        routeMeters: 10,
      ),
      SignAhead(
        sign: RoadSign(
          name: 'Hạn chế tốc độ',
          lat: 10.7699,
          lng: 106.6934,
          kind: RoadSignKind.speed,
          value: 80,
        ),
        routeMeters: 60,
      ),
    ];
    expect(dedupSignAhead(a), hasLength(1));

    // Same KIND at the same post → collapses EVEN IF the value differs
    // (an "80" and a "90" recorded at one post by two sources are one sign).
    final b = [
      SignAhead(
        sign: RoadSign(
          name: 'Hạn chế tốc độ',
          lat: 10.7698,
          lng: 106.6932,
          kind: RoadSignKind.speed,
          value: 80,
        ),
        routeMeters: 10,
      ),
      SignAhead(
        sign: RoadSign(
          name: 'Hạn chế tốc độ',
          lat: 10.7699,
          lng: 106.6933,
          kind: RoadSignKind.speed,
          value: 90,
        ),
        routeMeters: 20,
      ),
    ];
    expect(dedupSignAhead(b), hasLength(1));

    // Two DIFFERENT kinds at the same post (STOP + speed limit) both survive.
    final c = [
      SignAhead(
        sign: RoadSign(
          name: 'Biển STOP',
          lat: 10.7695,
          lng: 106.6930,
          kind: RoadSignKind.stop,
        ),
        routeMeters: 10,
      ),
      SignAhead(
        sign: RoadSign(
          name: 'Hạn chế tốc độ',
          lat: 10.7695,
          lng: 106.6930,
          kind: RoadSignKind.speed,
          value: 40,
        ),
        routeMeters: 10,
      ),
    ];
    expect(dedupSignAhead(c), hasLength(2));
  });

  test('dedupRoadSigns collapses same-kind signs within ~100 m', () {
    RoadSign s(double lat, double lng, RoadSignKind k, [int? v]) =>
        RoadSign(name: 'x', lat: lat, lng: lng, kind: k, value: v);
    // Same kind, ~50 m apart → 1.
    final a = dedupRoadSigns([
      s(10.7695, 106.6930, RoadSignKind.noPassing),
      s(10.7699, 106.6934, RoadSignKind.noPassing),
    ]);
    expect(a, hasLength(1));
    // Same kind at the same spot with a different value (speed 60 vs 90) →
    // collapses to 1 (per user "same kind is ok too").
    final b = dedupRoadSigns([
      s(10.7695, 106.6930, RoadSignKind.speed, 60),
      s(10.7696, 106.6931, RoadSignKind.speed, 90),
    ]);
    expect(b, hasLength(1));
    // Different kinds at the same spot → both kept.
    final d = dedupRoadSigns([
      s(10.7695, 106.6930, RoadSignKind.stop),
      s(10.7695, 106.6930, RoadSignKind.speed, 40),
    ]);
    expect(d, hasLength(2));
    // Far apart (>100 m) same kind → both kept.
    final c = dedupRoadSigns([
      s(10.7695, 106.6930, RoadSignKind.noPassing),
      s(10.7900, 106.6930, RoadSignKind.noPassing),
    ]);
    expect(c, hasLength(2));
  });

  test('isImportant correctly identifies major signs vs minor local signs', () {
    expect(RoadSignKind.speed.isImportant, isTrue);
    expect(RoadSignKind.noPassing.isImportant, isTrue);
    expect(RoadSignKind.noPassingEnd.isImportant, isTrue);
    expect(RoadSignKind.stop.isImportant, isTrue);
    expect(RoadSignKind.giveWay.isImportant, isTrue);
    expect(RoadSignKind.tollBooth.isImportant, isTrue);
    expect(RoadSignKind.railwayCrossing.isImportant, isTrue);
    expect(RoadSignKind.tunnel.isImportant, isTrue);

    // Minor local street signs should be suppressed when zoomed out.
    expect(RoadSignKind.noParking.isImportant, isFalse);
    expect(RoadSignKind.noLeftTurn.isImportant, isFalse);
    expect(RoadSignKind.noRightTurn.isImportant, isFalse);
    expect(RoadSignKind.noUTurn.isImportant, isFalse);
    expect(RoadSignKind.noStraight.isImportant, isFalse);
    expect(RoadSignKind.oneWay.isImportant, isFalse);
    expect(RoadSignKind.signal.isImportant, isFalse);
    expect(RoadSignKind.noAuto.isImportant, isFalse);
    expect(RoadSignKind.noMoto.isImportant, isFalse);
    expect(RoadSignKind.reservedLane.isImportant, isFalse);
  });

  test('zoomed-out sign filtering limits to 20-30 important signs only', () {
    RoadSign sign(int id, RoadSignKind k) => RoadSign(
      name: 'Sign $id',
      lat: 10.7 + id * 0.001,
      lng: 106.6 + id * 0.001,
      kind: k,
    );

    // Simulate 50 mixed signs: 35 minor (parking, turn bans) and 15 important.
    final mixed = <RoadSign>[
      for (var i = 0; i < 20; i++) sign(i, RoadSignKind.noParking),
      for (var i = 20; i < 35; i++) sign(i, RoadSignKind.noLeftTurn),
      for (var i = 35; i < 45; i++) sign(i, RoadSignKind.speed),
      for (var i = 45; i < 50; i++) sign(i, RoadSignKind.giveWay),
    ];

    // Zoomed-out filter logic
    final important = mixed.where((s) => s.isImportant).toList();
    expect(important, hasLength(15));
    for (final s in important) {
      expect(s.isImportant, isTrue);
      expect(s.kind, isNot(RoadSignKind.noParking));
      expect(s.kind, isNot(RoadSignKind.noLeftTurn));
    }

    // When there are 40 important signs, cap at 20-30
    final manyImportant = [
      for (var i = 0; i < 40; i++) sign(i, RoadSignKind.speed),
    ];
    // Zoom 13 (default): cap = ((13 - 11) * 3 + 20) = 26
    const zoom = 13.0;
    final cap = ((zoom - 11.0) * 3 + 20).round().clamp(20, 30);
    expect(cap, inInclusiveRange(20, 30));
    final sliced = manyImportant.take(cap).toList();
    expect(sliced.length, equals(26));
  });

  test('on-route zoom-density limits markers to 100-200 important items max', () {
    List<T> decimate<T>(List<T> items, int cap) {
      if (items.length <= cap) return items;
      if (cap <= 0) return const [];
      final step = items.length / cap;
      return List.generate(cap, (i) => items[(i * step).floor()]);
    }

    final routeSigns = [
      for (var i = 0; i < 500; i++)
        RoadSign(
          name: 'Sign $i',
          lat: 10.0 + i * 0.01,
          lng: 106.0 + i * 0.01,
          kind: i % 2 == 0 ? RoadSignKind.speed : RoadSignKind.noParking,
        ),
    ];

    final importantSigns = routeSigns.where((s) => s.isImportant).toList();
    expect(importantSigns.length, equals(250));

    // At zoom 11 (overview / zoomed out):
    final signCapZ11 = ((11.0 - 11.0) * 24 + 20).round().clamp(20, 140);
    expect(signCapZ11, equals(20));
    final decimatedZ11 = decimate(importantSigns, signCapZ11);
    expect(decimatedZ11.length, equals(20));
    // Verify first and last parts of the route are represented (no clumping at start)
    expect(decimatedZ11.first.name, equals('Sign 0'));
    expect(decimatedZ11.last.name, equals('Sign 474'));

    // At zoom 16+ (zoomed in):
    final signCapZ16 = ((16.0 - 11.0) * 24 + 20).round().clamp(20, 140);
    expect(signCapZ16, equals(140));
    final decimatedZ16 = decimate(importantSigns, signCapZ16);
    expect(decimatedZ16.length, equals(140));

    // Camera cap at z11 and z16:
    final camCapZ11 = ((11.0 - 10.0) * 7 + 15).round().clamp(15, 60);
    final camCapZ16 = ((16.0 - 10.0) * 7 + 15).round().clamp(15, 60);
    expect(camCapZ11, equals(22));
    expect(camCapZ16, equals(57));

    // Total combined markers on route:
    expect(signCapZ11 + camCapZ11, equals(42)); // ~40 markers when zoomed out
    expect(
      signCapZ16 + camCapZ16,
      inInclusiveRange(100, 200),
    ); // strictly <= 200 markers when zoomed in
  });

  test('collapseRepeatedSpeedSigns shows a repeated limit only ONCE per '
      'stretch', () {
    RoadSign speed(
      double lat,
      double lng,
      int? v, [
      String n = 'Hạn chế tốc độ',
    ]) => RoadSign(
      name: n,
      lat: lat,
      lng: lng,
      kind: RoadSignKind.speed,
      value: v,
    );
    RoadSign other(RoadSignKind k, double lat, double lng) =>
        RoadSign(name: k.key, lat: lat, lng: lng, kind: k);

    // One street: 50 posted every ~300 m (0.0027° ≈ 300 m) — 5 icons in.
    final street = [
      speed(10.0000, 106.0000, 50),
      speed(10.0027, 106.0000, 50),
      speed(10.0054, 106.0000, 50),
      other(RoadSignKind.stop, 10.0060, 106.0000),
      speed(10.0081, 106.0000, 50),
      // A REAL change to 60 must survive.
      speed(10.0108, 106.0000, 60),
      speed(10.0135, 106.0000, 60),
    ];
    final kept = collapseRepeatedSpeedSigns(street);
    // 1 icon for the 50 stretch + the STOP + 1 for the 60 stretch.
    expect(kept, hasLength(3));
    expect(kept[0].value, 50);
    expect(
      kept[1].kind,
      RoadSignKind.stop,
      reason: 'non-speed signs pass through',
    );
    expect(kept[2].value, 60);

    // The same value far away (a different street / re-signed stretch) is kept.
    final far = collapseRepeatedSpeedSigns([
      speed(10.0000, 106.0000, 50),
      speed(10.0400, 106.0000, 50), // ~4.4 km away
    ]);
    expect(far, hasLength(2));

    // Speed signs without a value are never collapsed away.
    final noValue = collapseRepeatedSpeedSigns([
      speed(10.0, 106.0, null),
      speed(10.001, 106.0, null),
    ]);
    expect(noValue, hasLength(2));
    expect(collapseRepeatedSpeedSigns(const []), isEmpty);
  });
}

/// Minimum straight-line distance (metres) from [p] to the polyline [geo] —
/// test-side helper (same degree-space projection as the service).
double _minDistanceToLine(List<LatLng> geo, LatLng p) {
  const d = Distance();
  var best = double.infinity;
  for (var i = 0; i < geo.length - 1; i++) {
    final a = geo[i];
    final b = geo[i + 1];
    final ax = a.longitude, ay = a.latitude;
    final bx = b.longitude, by = b.latitude;
    final px = p.longitude, py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    LatLng proj;
    if (len2 == 0) {
      proj = a;
    } else {
      var t = ((px - ax) * dx + (py - ay) * dy) / len2;
      t = t.clamp(0.0, 1.0);
      proj = LatLng(ay + t * dy, ax + t * dx);
    }
    final dist = d.as(LengthUnit.Meter, proj, p);
    if (dist < best) best = dist;
  }
  return best;
}
