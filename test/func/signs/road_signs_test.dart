/// Road signs — the bundled DB, its placement, its artwork, its scans
///
/// Phase-1 consolidation (2026-09-28): these were 7 separate
/// files, one per bugfix, each re-loading the same bundled pack in its own
/// test isolate. The assertions are unchanged — each former file is one
/// group below, so its file-local helpers keep their own scope.
///
///   ///   offline_road_sign_test.dart
///   sign_precision_test.dart
///   sign_behind_car_test.dart
///   sign_zone_scan_test.dart
///   maneuver_sign_test.dart
///   sign_icons_test.dart
///   lamdong_km_cameras_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_scan.dart';
import 'package:navbridge/services/offline_scan_isolate.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/ui/sign_icons.dart';
// ---- from offline_road_sign_test.dart ----
const _offlineRoadSignStubNote = 'bundled sign DB is a stub (see tool/stub_assets.sh)';



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

// ---- from sign_behind_car_test.dart ----
RoadSign _signBehindCarSign(double lat, double lng, [RoadSignKind? kind]) => RoadSign(
  kind: kind ?? RoadSignKind.stop,
  lat: lat,
  lng: lng,
  value: null,
  name: '',
  source: 'test',
);

// ---- from sign_zone_scan_test.dart ----
const _latDeg = 111320.0; // metres per degree of latitude
const _lngDeg = 109640.0; // metres per degree of longitude at 10° N

final _route = <LatLng>[
  for (var i = 0; i <= 30; i++) LatLng(10.0 + i * 0.001, 106.0),
];

LatLng _at(double alongM, {double sideM = 0}) => LatLng(
      10.0 + alongM / _latDeg,
      106.0 + sideM / _lngDeg,
    );

RoadSign _signZoneScanSign(RoadSignKind kind, double alongM, {double sideM = 0}) => RoadSign(
      name: kind.label,
      lat: _at(alongM, sideM: sideM).latitude,
      lng: _at(alongM, sideM: sideM).longitude,
      kind: kind,
    );

double _lateralFor(RoadSign s) =>
    zoneSignKinds.contains(s.kind) ? kZoneLateralMeters : kRoadsideLateralMeters;

List<(int, double)> _scan(List<RoadSign> signs, {double maxAheadMeters = 1200}) =>
    pointsAheadOnRoute<RoadSign>(
      (const LatLng(10.0, 106.0), _route, signs, maxAheadMeters, 40.0),
      lateralFor: _lateralFor,
    );

// ---- from maneuver_sign_test.dart ----
const _uTurnUnknown = -98;
const _uTurnLeft = -8;
const _keepLeft = -7;
const _roundaboutExit = -6;
const _sharpLeft = -3;
const _left = -2;
const _slightLeft = -1;
const _continue = 0;
const _slightRight = 1;
const _right = 2;
const _sharpRight = 3;
const _finish = 4;
const _reachedVia = 5;
const _roundaboutUse = 6;
const _keepRight = 7;
const _uTurnRight = 8;
const _ferry = 9;

(int, String) _spoken(int sign) {
  final (type, modifier) = osrmManeuverForInstructionSign(sign);
  final icon = iconForManeuver(type, modifier);
  return (icon, maneuverVerb(icon));
}

// ---- from lamdong_km_cameras_test.dart ----
const _lamdongKmCamerasStubNote = 'bundled camera DB is a stub (see tool/stub_assets.sh)';

const _announced = <(String, String, double, double, double)>[
  ('QL28B', 'Km01+610', 11.20530, 108.36077, 304.1),
  ('QL28B', 'Km16+900', 11.32831, 108.34620, 177.5),
  ('QL28B', 'Km18+800', 11.34464, 108.34968, 11.2),
  ('QL28B', 'Km57+390', 11.55665, 108.34739, 191.1),
  ('ĐT724', 'Km0+780', 11.68556, 108.32387, 294.5),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('offline_road_sign', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      test('loads bundled road-sign index', () async {
        final signs = await loadOfflineRoadSigns();
        if (signs.isEmpty) {
          markTestSkipped(_offlineRoadSignStubNote);
          return;
        }
        for (final s in signs) {
          expect(s.lat, inInclusiveRange(8.0, 23.6));
          expect(s.lng, inInclusiveRange(102.0, 110.0));
          expect(s.name, isNotEmpty);
          expect(RoadSignKind.values, contains(s.kind));
        }
      });

      test('no impossible speed value survives the load (≤ 120 km/h)', () async {
        // 7 VietMap E-DOG rows read 135–157 km/h, and nav_signs.dart adopts the
        // nearest speed sign's value as the LIVE limit — so one of these could post
        // a 157 km/h limit on the dashboard. See isImpossibleSpeedSign.
        const legal = RoadSign(
          name: 'Hạn chế tốc độ 120',
          lat: 10,
          lng: 106,
          kind: RoadSignKind.speed,
          value: 120,
        );
        const impossible = RoadSign(
          name: 'Hạn chế tốc độ 157 km/h',
          lat: 11.132,
          lng: 107.731,
          kind: RoadSignKind.speed,
          value: 157,
        );
        expect(isImpossibleSpeedSign(legal), isFalse);
        expect(isImpossibleSpeedSign(impossible), isTrue);

        final signs = await loadOfflineRoadSigns();
        if (signs.isEmpty) {
          markTestSkipped(_offlineRoadSignStubNote);
          return;
        }
        final bad = signs.where(isImpossibleSpeedSign).toList();
        expect(
          bad,
          isEmpty,
          reason: 'stored values: ${bad.take(5).map((s) => s.value).toList()}',
        );
      });

      test('index covers all sign kinds', () async {
        final signs = await loadOfflineRoadSigns();
        if (signs.isEmpty) {
          markTestSkipped(_offlineRoadSignStubNote);
          return;
        }
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
          if (rows.isEmpty) {
            markTestSkipped(_offlineRoadSignStubNote);
            return;
          }
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
        if (signs.isEmpty) {
          markTestSkipped(_offlineRoadSignStubNote);
          return;
        }
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
        if (signs.isEmpty) {
          markTestSkipped(_offlineRoadSignStubNote);
          return;
        }
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
  });

  group('sign_precision', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      test('a coarse coordinate is refused, a fine one is kept', () {
        // 3 decimals = a 0.001° grid ≈ 111 m ⇒ up to ±55 m of error.
        expect(
          signCoordsAreUsable(const RoadSign(
              name: 'Cấm rẽ trái', lat: 10.798, lng: 106.658,
              kind: RoadSignKind.noLeftTurn)),
          isFalse,
        );
        expect(
          signCoordsAreUsable(const RoadSign(
              name: 'Chỉ rẽ trái', lat: 10.792, lng: 106.672,
              kind: RoadSignKind.onlyLeft)),
          isFalse,
        );
        expect(
          signCoordsAreUsable(const RoadSign(
              name: 'Cấm rẽ trái', lat: 10.79812, lng: 106.65831,
              kind: RoadSignKind.noLeftTurn)),
          isTrue,
        );
      });

      test('the bundled index keeps every well-placed sign and drops the rest',
          () async {
        final signs = await loadOfflineRoadSigns();
        if (signs.isEmpty) return; // CI ships stub assets

        // Nothing coarse survives, whatever the kind.
        final coarse = signs.where((s) => !signCoordsAreUsable(s)).toList();
        expect(coarse, isEmpty,
            reason: 'a ${coarse.isEmpty ? "" : coarse.first.kind.key} sign with a '
                'coarse coordinate reached the app');

        // The turn signs are placed now: `tools/signs/repair_sign_coords.py`
        // restored them from the Waze decode (6-decimal source, `source: waze`) and
        // from E-DOG, so the guard is only the net for the 1,306 rows no source can
        // place — it used to drop 9,762 rows out of 45,197.
        final onlyLeft = signs.where((s) => s.kind == RoadSignKind.onlyLeft).toList();
        expect(onlyLeft, hasLength(6),
            reason: 'the 6 only_left rows exist in the Waze source and are precise '
                'after the repair; before it they were all on the 0.001° grid');
        expect(onlyLeft.every((s) => s.source == 'waze'), isTrue);
        expect(signs.where((s) => s.kind == RoadSignKind.noLeftTurn).length,
            greaterThan(300));
        expect(signs.where((s) => s.kind == RoadSignKind.speed).length,
            greaterThan(15000));
        // …and the kinds whose feed was always fine keep their rows.
        expect(signs.where((s) => s.kind == RoadSignKind.stop).length,
            greaterThan(300));
        expect(signs.where((s) => s.kind == RoadSignKind.signal).length,
            greaterThan(3000));
      });
  });

  group('sign_behind_car', () {
      // Car at the origin, heading NORTH.
      const car = LatLng(10.000000, 106.000000);
      // ~111 m north (ahead), ~111 m south (behind), ~111 m east (to the side).
      final ahead = _signBehindCarSign(10.001000, 106.000000);
      final behind = _signBehindCarSign(9.999000, 106.000000);
      final side = _signBehindCarSign(10.000000, 106.001000);


      test('5 cases', () {
      // ---- case: a sign ahead is kept, one already passed is removed ----
      (() {
          final kept = signsAheadOfDriver([ahead, behind, side],
              car: car, headingDeg: 0);
          expect(kept, contains(ahead));
          expect(kept, isNot(contains(behind)));

      })();


      // ---- case: turning back re-admits the sign that was behind ----
      (() {
          // Same list, same car — heading 180 (south) instead of 0 (north).
          final kept = signsAheadOfDriver([ahead, behind, side],
              car: car, headingDeg: 180);
          expect(kept, contains(behind), reason: 'now it is in front');
          expect(kept, isNot(contains(ahead)));

      })();


      // ---- case: a sign square to the side is kept while heading past it, dropped once  ----
      (() {
          // Due east of the car: neutral at heading 0/180 (along ≈ 0), in front at
          // 90, and 111 m BEHIND at 270 — the last one is a passed sign like any
          // other, so it goes.
          expect(signsAheadOfDriver([side], car: car, headingDeg: 0), contains(side));
          expect(signsAheadOfDriver([side], car: car, headingDeg: 180), contains(side));
          expect(signsAheadOfDriver([side], car: car, headingDeg: 90), contains(side));
          expect(signsAheadOfDriver([side], car: car, headingDeg: 270),
              isNot(contains(side)));

      })();


      // ---- case: the sign being passed right now is kept until it is 40 m back ----
      (() {
          final justBehind = _signBehindCarSign(9.999900, 106.000000); // ~12 m south
          final farBehind = _signBehindCarSign(9.999500, 106.000000); // ~55 m south
          final kept = signsAheadOfDriver([justBehind, farBehind],
              car: car, headingDeg: 0);
          expect(kept, contains(justBehind));
          expect(kept, isNot(contains(farBehind)));

      })();


      // ---- case: a diagonal sign counts by its component along the heading ----
      (() {
          // ~111 m east AND ~111 m north of the car: firmly in front at heading 45,
          // squarely behind at 225.
          final northEast = _signBehindCarSign(10.001000, 106.001000);
          expect(signsAheadOfDriver([northEast], car: car, headingDeg: 45),
              contains(northEast));
          expect(signsAheadOfDriver([northEast], car: car, headingDeg: 225),
              isNot(contains(northEast)));

      })();
      });

  });

  group('sign_zone_scan', () {
      group('resident-area (in/out) boundaries in the ahead scan', () {

        test('7 cases', () {
        // ---- case: a boundary 60 m off the carriageway is still ON the route ----
        (() {
            // Both directions of the pair, so the test covers "in" AND "out".
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 300, sideM: 60),
              _signZoneScanSign(RoadSignKind.populatedEnd, 900, sideM: 60),
            ];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0, 1],
                reason: 'the in and the out boundary must both be seen');

        })();


        // ---- case: the in/out pair comes back in route order, at its own distance ----
        (() {
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 250, sideM: 20),
              _signZoneScanSign(RoadSignKind.populatedEnd, 700, sideM: 20),
            ];
            final hits = _scan(signs);
            expect(hits.length, 2);
            expect(signs[hits[0].$1].kind, RoadSignKind.populated);
            expect(signs[hits[1].$1].kind, RoadSignKind.populatedEnd);
            expect(hits[0].$2, closeTo(250, 15));
            expect(hits[1].$2, closeTo(700, 15));
            expect(hits[0].$2, lessThan(hits[1].$2),
                reason: 'entering must be announced before leaving');

        })();


        // ---- case: an ordinary sign at the same offset is another street, not ours ----
        (() {
            // The 40 m corridor exists for exactly this: a STOP 60 m to the side
            // stands on a parallel road. The boundary kinds are the only exception.
            final signs = [
              _signZoneScanSign(RoadSignKind.stop, 300, sideM: 60),
              _signZoneScanSign(RoadSignKind.speed, 300, sideM: 60),
            ];
            expect(_scan(signs), isEmpty);

        })();


        // ---- case: a boundary beyond the zone corridor is still rejected ----
        (() {
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 300, sideM: kZoneLateralMeters + 40),
            ];
            expect(_scan(signs), isEmpty);

        })();


        // ---- case: the corridor applies to the boundary, not to the whole scan ----
        (() {
            // One wide-corridor kind must not let its neighbour through: same call,
            // same distance, only the KIND differs.
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 400, sideM: 100),
              _signZoneScanSign(RoadSignKind.noPassing, 400, sideM: 100), // zone kind, but
              _signZoneScanSign(RoadSignKind.noParking, 400, sideM: 100), // roadside kind
            ];
            final hits = _scan(signs);
            expect(hits.map((h) => signs[h.$1].kind),
                [RoadSignKind.populated, RoadSignKind.noPassing]);

        })();


        // ---- case: a boundary past the look-ahead window is not reported ----
        (() {
            final signs = [_signZoneScanSign(RoadSignKind.populated, 2500, sideM: 30)];
            expect(_scan(signs, maxAheadMeters: 1200), isEmpty);
            expect(_scan(signs, maxAheadMeters: 3000).map((h) => h.$1), [0]);

        })();


        // ---- case: a boundary ON the road works for any vehicle-visible offset ----
        (() {
            final signs = [_signZoneScanSign(RoadSignKind.populated, 500)];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0]);
            expect(hits.single.$2, closeTo(500, 15));

        })();
        });


        test('9 cases', () {
        // ---- case: LEAVING town alone announces — the drive began inside ----
        (() {
            // No entry boundary exists: the car was already in the built-up area
            // when the trip started, so `populated_end` has no partner. It must
            // still be reported, or the driver is never told they left.
            final signs = [_signZoneScanSign(RoadSignKind.populatedEnd, 800)];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0]);
            expect(signs[hits.single.$1].kind, RoadSignKind.populatedEnd);

        })();


        // ---- case: ENTERING town alone announces — the drive ends inside ----
        (() {
            final signs = [_signZoneScanSign(RoadSignKind.populated, 800)];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0]);
            expect(signs[hits.single.$1].kind, RoadSignKind.populated);

        })();


        // ---- case: two pairs on one route all come back, in route order ----
        (() {
            // A drive that passes through two towns: in/out, then in/out again.
            // Every boundary is its own announcement, so all four must survive
            // the scan — not just the first pair.
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 200, sideM: 30),
              _signZoneScanSign(RoadSignKind.populatedEnd, 600, sideM: 30),
              _signZoneScanSign(RoadSignKind.populated, 900, sideM: 90),
              _signZoneScanSign(RoadSignKind.populatedEnd, 1100, sideM: 90),
            ];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0, 1, 2, 3]);
            expect(
              hits.map((h) => signs[h.$1].kind),
              [
                RoadSignKind.populated,
                RoadSignKind.populatedEnd,
                RoadSignKind.populated,
                RoadSignKind.populatedEnd,
              ],
              reason: 'the pairs must stay in order: in before out, twice',
            );
            expect(hits.map((h) => h.$2),
                everyElement(isA<double>()));
            expect(hits[0].$2, closeTo(200, 30));
            expect(hits[1].$2, closeTo(600, 30));
            expect(hits[2].$2, closeTo(900, 30));
            expect(hits[3].$2, closeTo(1100, 30));

        })();


        // ---- case: a boundary on the FAR side of the carriageway is ours too ----
        (() {
            // The lateral corridor is a distance, not a direction: a zone vertex
            // mapped on the other side of the road is the same boundary.
            final near = [_signZoneScanSign(RoadSignKind.populated, 400, sideM: kZoneLateralMeters - 10)];
            final far = [_signZoneScanSign(RoadSignKind.populated, 400, sideM: -(kZoneLateralMeters - 10))];
            expect(_scan(near).map((h) => h.$1), [0]);
            expect(_scan(far).map((h) => h.$1), [0],
                reason: 'the opposite side of the road is still this road');

        })();


        // ---- case: exactly ON the corridor edge is in, one metre past is out ----
        (() {
            // The comparison is `off > limit`, so the boundary is inclusive: a
            // zone vertex at exactly 150 m stands on the edge of the road's own
            // footprint and must not be lost to a rounding difference.
            expect(
              _scan([_signZoneScanSign(RoadSignKind.populated, 400, sideM: kZoneLateralMeters)]).map((h) => h.$1),
              [0],
            );
            expect(
              _scan([_signZoneScanSign(RoadSignKind.populated, 400, sideM: kZoneLateralMeters + 1)]),
              isEmpty,
            );

        })();


        // ---- case: a boundary left well BEHIND is not reported ----
        (() {
            // Leaving a town is announced when the car reaches the boundary, not
            // for the rest of the drive. The scan window deliberately keeps a
            // 200 m lead-in behind the car (so a fix that lands just past a
            // vertex still projects onto the right segment), so "behind" here
            // means beyond that lead-in — inside it the boundary reads as 0 m
            // ahead, which is the "you are AT it" case right below.
            expect(_scan([_signZoneScanSign(RoadSignKind.populatedEnd, -400)]),
                isEmpty);
            final at = _scan([_signZoneScanSign(RoadSignKind.populated, 0)]);
            expect(at.map((h) => h.$1), [0],
                reason: 'a boundary at the car is announced, not lost');
            expect(at.single.$2, closeTo(0, 1));

        })();


        // ---- case: boundaries are reported by DISTANCE, not by kind order ----
        (() {
            // A zone dump can list the exit vertex before the entry one. The scan
            // sorts by distance, so the nearer boundary is announced first even
            // when the data says "out" first — otherwise the driver hears "Hết"
            // before "Bắt đầu".
            final signs = [
              _signZoneScanSign(RoadSignKind.populatedEnd, 300),
              _signZoneScanSign(RoadSignKind.populated, 900),
            ];
            final hits = _scan(signs);
            expect(hits.map((h) => h.$1), [0, 1],
                reason: 'strictly ordered by distance ahead');
            expect(hits[0].$2, lessThan(hits[1].$2));
            expect(signs[hits[0].$1].kind, RoadSignKind.populatedEnd);

        })();


        // ---- case: an identical pair (same coords) is reported once each ----
        (() {
            // Some roads carry the entry and the exit at the SAME vertex: a
            // town the driver clips the corner of. Both rows are distinct
            // records, so both are reported — the announcement layer is what
            // decides they are two different callouts, not the scan.
            final signs = [
              _signZoneScanSign(RoadSignKind.populated, 500),
              _signZoneScanSign(RoadSignKind.populatedEnd, 500),
            ];
            final hits = _scan(signs);
            expect(hits, hasLength(2));
            expect(hits.map((h) => h.$1).toSet(), {0, 1});
            expect(hits.every((h) => (h.$2 - 500).abs() < 15), isTrue);

        })();


        // ---- case: the SAME vertex twice (a duplicated dump row) is two hits ----
        (() {
            // E-DOG repeats boundary vertices along a way. Duplicates are not
            // deduped here on purpose: deduping by coordinate would also swallow
            // the genuine in/out pair above, and the announce layer already
            // speaks each (kind, coordinate) at most once per zone.
            final dup = _signZoneScanSign(RoadSignKind.populated, 700);
            final hits = _scan([dup, dup]);
            expect(hits, hasLength(2));
            expect(hits.map((h) => h.$1).toSet(), {0, 1},
                reason: 'the two records are distinct rows, not one deduped hit');
            expect(dup.kind, RoadSignKind.populated);
            expect(hits.map((h) => h.$2), everyElement(closeTo(700, 15)));

        })();
        });

      });

      group('the corridor constants', () {
        test('the zone corridor is wider than the roadside one', () {
          expect(kZoneLateralMeters, 150.0);
          expect(kRoadsideLateralMeters, 40.0);
          expect(kZoneLateralMeters, greaterThan(kRoadsideLateralMeters));
        });

        test('both boundary kinds are zone kinds (so both get it)', () {
          expect(zoneSignKinds, contains(RoadSignKind.populated));
          expect(zoneSignKinds, contains(RoadSignKind.populatedEnd));
        });
      });
  });

  group('maneuver_sign', () {
      group('lateral signs turn the right way', () {

        test('3 cases', () {
        // ---- case: left family ----
        (() {
            expect(_spoken(_sharpLeft), (iconTurnLeft, 'rẽ trái'));
            expect(_spoken(_left), (iconTurnLeft, 'rẽ trái'));
            expect(_spoken(_slightLeft), (iconSlightLeft, 'rẽ trái nhẹ'));

        })();


        // ---- case: right family ----
        (() {
            expect(_spoken(_sharpRight), (iconTurnRight, 'rẽ phải'));
            expect(_spoken(_right), (iconTurnRight, 'rẽ phải'));
            expect(_spoken(_slightRight), (iconSlightRight, 'rẽ phải nhẹ'));

        })();


        // ---- case: straight ----
        (() {
            expect(_spoken(_continue), (iconStraight, 'đi thẳng'));

        })();
        });

      });

      group('roundabout', () {

        test('4 cases', () {
        // ---- case: 6 (USE) and -6 (EXIT) are roundabouts ----
        (() {
            expect(osrmManeuverForInstructionSign(_roundaboutUse).$1, 'roundabout');
            expect(_spoken(_roundaboutUse), (iconRoundabout, 'đi theo vòng xuyến'));
            expect(osrmManeuverForInstructionSign(_roundaboutExit).$1, 'roundabout');

        })();


        // ---- case: ⭐ 7 is KEEP RIGHT, not a roundabout (the regression) ----
        (() {
            final (type, _) = osrmManeuverForInstructionSign(_keepRight);
            expect(type, isNot('roundabout'));
            expect(_spoken(_keepRight), (iconSlightRight, 'rẽ phải nhẹ'));

        })();


        // ---- case: -7 is KEEP LEFT, not "continue straight" ----
        (() {
            expect(_spoken(_keepLeft), (iconSlightLeft, 'rẽ trái nhẹ'));

        })();


        // ---- case: no other sign can ever look like a roundabout ----
        (() {
            // The invariant that stops this class of bug coming back: scan the whole
            // plausible sign range, not just the codes we happen to think of.
            final roundabouts = <int>[];
            for (var sign = -99; sign <= 99; sign++) {
              final (type, modifier) = osrmManeuverForInstructionSign(sign);
              if (iconForManeuver(type, modifier) == iconRoundabout) {
                roundabouts.add(sign);
              }
            }
            expect(roundabouts, unorderedEquals([_roundaboutUse, _roundaboutExit]));

        })();
        });

      });

      group('u-turns, stops and ferries', () {

        test('4 cases', () {
        // ---- case: all three u-turn codes say "quay đầu" ----
        (() {
            for (final sign in [_uTurnUnknown, _uTurnLeft, _uTurnRight]) {
              final (icon, verb) = _spoken(sign);
              expect(
                icon,
                anyOf(iconUturnLeft, iconUturnRight),
                reason: 'sign $sign',
              );
              expect(verb, 'quay đầu', reason: 'sign $sign');
            }

        })();


        // ---- case: 4 (FINISH) and 5 (REACHED_VIA) arrive ----
        (() {
            expect(_spoken(_finish), (iconArrive, 'đến nơi'));
            expect(_spoken(_reachedVia), (iconArrive, 'đến nơi'));

        })();


        // ---- case: 9 is a ferry leg, not an arrival ----
        (() {
            expect(osrmManeuverForInstructionSign(_ferry).$1, 'ferry');
            expect(_spoken(_ferry).$1, isNot(iconArrive));

        })();


        // ---- case: unknown codes degrade to "đi thẳng" rather than crashing ----
        (() {
            for (final sign in <int>[-99, -5, -4, 10, 42, 1000]) {
              final (icon, verb) = _spoken(sign);
              expect(icon, iconStraight, reason: 'sign $sign');
              expect(verb, 'đi thẳng', reason: 'sign $sign');
            }

        })();
        });

      });
  });

  group('sign_icons', () {

      test('4 cases', () {
      // ---- case: every kind a data source can emit draws official QCVN artwork ----
      (() {
          // The kinds the three generators actually produce:
          //   Waze decode    — tools/signs/build_waze_signs.py   (TYPE_KIND)
          //   VietMap E-DOG  — tools/signs/build_vietmap.py      (EDOG_SIGN)
          //   DATMAP merge   — tools/signs/rebuild_waze_assets.py + the DATMAP tipos
          // A sign from EITHER source has to show the Vietnamese sign PICTURE, not one
          // of our painters (user: "waze sign and vietmap sign must aligned to the
          // vietnamese sign data png").
          const fromData = {
            // Waze decode
            RoadSignKind.noPassing,
            RoadSignKind.noPassingEnd,
            RoadSignKind.noLeftTurn,
            RoadSignKind.noRightTurn,
            RoadSignKind.noUTurn,
            RoadSignKind.noLeftUTurn,
            RoadSignKind.noRightUTurn,
            RoadSignKind.onlyStraight,
            RoadSignKind.onlyLeft,
            RoadSignKind.onlyRight,
            RoadSignKind.endProhibitions,
            // VietMap E-DOG
            RoadSignKind.slowDown,
            RoadSignKind.tunnel,
            RoadSignKind.railwayCrossing,
            // DATMAP / OSM extras that reach the map
            RoadSignKind.noAuto,
            RoadSignKind.oneWay,
            RoadSignKind.noMoto,
            RoadSignKind.noParking,
            RoadSignKind.stop,
            RoadSignKind.giveWay,
          };
          // The two exceptions, both deliberate:
          //   speed     — the sign is a white disc carrying the km/h from the DATA, so
          //               it must stay painted (`_SpeedPainter`);
          //   tollBooth — no QCVN sign for a toll plaza was found (Commons' I.428b/c
          //               are EV/gas stations), so it keeps its text chip and is NOT
          //               in the list above.
          for (final kind in fromData) {
            expect(
              SignIcon.assetFor(kind),
              isNotNull,
              reason: '$kind comes from the sign data but has no real artwork',
            );
          }
          expect(SignIcon.assetFor(RoadSignKind.speed), isNull,
              reason: 'a speed sign draws its own number');

      })();



      // ---- case: the turn prohibitions keep their verified artwork ----
      (() {
          // noUTurn is BACK on real artwork: Commons `Vietnam road sign P124a1.svg`
          // (public domain, "No U-turn to the left") replaced first the cấm-vượt image
          // that used to sit in this slot, then a sign we had drawn ourselves.
          // The two combinations are the Commons `P124c` / `P124d`, metadata
          // "No left/right turn or U-turn" — and used to be painted as a
          // left/right arrow with a second U-turn arrow stacked over it, which is not
          // the real sign.
          for (final kind in [
            RoadSignKind.noLeftTurn,
            RoadSignKind.noRightTurn,
            RoadSignKind.noUTurn,
            RoadSignKind.noLeftUTurn,
            RoadSignKind.noRightUTurn,
          ]) {
            expect(
              SignIcon.assetFor(kind),
              isNotNull,
              reason: '$kind lost its image',
            );
          }

      })();


      // ---- case: every mapped asset exists, is non-trivial and is a PNG ----
      (() {
          const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
          var mapped = 0;
          for (final kind in RoadSignKind.values) {
            final path = SignIcon.assetFor(kind);
            if (path == null) continue;
            mapped++;
            final f = File(path);
            expect(f.existsSync(), isTrue, reason: '$path is mapped but missing');
            expect(f.lengthSync(), greaterThan(1000), reason: '$path looks empty');
            expect(
              f.readAsBytesSync().sublist(0, 8),
              pngMagic,
              reason: '$path is not a PNG',
            );
          }
          expect(mapped, greaterThan(0), reason: 'no artwork is used at all');

      })();


      // ---- case: no bundled sign PNG is left unused (it could be re-mapped by mistake) ----
      (() {
            final dir = Directory('assets/offline_map/signs');
            if (!dir.existsSync()) return;
            final mapped = {
              for (final kind in RoadSignKind.values)
                if (SignIcon.assetFor(kind) != null)
                  SignIcon.assetFor(kind)!.split('/').last,
            };
            for (final f in dir.listSync().whereType<File>()) {
              final name = f.path.split(Platform.pathSeparator).last;
              expect(
                mapped,
                contains(name),
                reason: '$name is bundled but shown for no kind — delete or map it',
              );
            }

      })();
      });

  });

  group('lamdong_km_cameras', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      test('the Lâm Đồng km-post cameras are in the DB', () async {
        final cams = await loadOfflineCameras();
        if (cams.isEmpty) {
          markTestSkipped(_lamdongKmCamerasStubNote);
          return;
        }
        const d = Distance();
        for (final (road, km, lat, lng, _) in _announced) {
          final hit = cams.where(
            (c) =>
                c.focus == 'speed' &&
                c.district == 'Lâm Đồng' &&
                d.as(LengthUnit.Meter, c.pos, LatLng(lat, lng)) < 60,
          );
          expect(hit, isNotEmpty, reason: '$road $km missing from the camera DB');
          final cam = hit.first;
          expect(cam.name, contains(km), reason: '$road $km name');
          expect(cam.source, 'police', reason: '$road $km source (công an)');
          expect(cam.type, 'speed_camera', reason: '$road $km type');
        }
      });

      test('each camera sits on the road it was announced on', () async {
        await loadOfflineSpeedLimits();
        if (!speedLimitsPopulated) return; // CI ships stub assets
        for (final (road, km, lat, lng, bearing) in _announced) {
          await speedLimitAt(LatLng(lat, lng), headingDeg: bearing);
          final street = lastWazeStreetName();
          expect(
            streetNameMatches(road, street),
            isTrue,
            reason: '$road $km sits on "$street", not on $road',
          );
        }
      });
  });
}
