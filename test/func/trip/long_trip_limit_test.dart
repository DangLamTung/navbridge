// REAL-DATA test: the posted-limit chain on the LONG trip's own coordinates.
//
// Why: driving the 1,686 km QL1A fixture in the web harness, the dial showed no
// limit while the pack had one within 25 m at 78 of 79 sampled points. The app's
// own per-fix call is `lookupSpeedLimit(...)` — this test makes that exact call
// at points along the route, so "the algorithm is silent on the long trip" can
// be localised to the chain or to the page that feeds it, off-device.
//
// Needs the real 28 MB pack (see `tool/stub_assets.sh`); with CI stubs it
// reports SKIPPED instead of passing quietly.
//
//   flutter test test/trip        (also part of tool/check.sh)
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

/// Route points (from `assets/trips/_hnsg.json`, the 1 Hz Hà Nội → Sài Gòn
/// drive) with what the chain answers there. Values measured with the app's own
/// reader in this test; the repo's Python port agrees everywhere except the last
/// point, where two parallel Waze records of 'Cộng Hòa' (50 and 60) sit 2-3 m
/// apart — the reader's continuity rule picks 60.
const _samples = <({String what, LatLng at, int kmh})>[
  (what: 'Hà Nội start', at: LatLng(21.02780, 105.83420), kmh: 50),
  (what: 'Quảng Bình (Đường Hoành Sơn)', at: LatLng(18.00360, 106.45800), kmh: 60),
  (what: 'Quảng Ngãi (QL1)', at: LatLng(15.52140, 108.55370), kmh: 60),
  (what: 'Nha Trang (Hai tháng Tư)', at: LatLng(12.28630, 109.19090), kmh: 60),
  (what: 'TP.HCM (Cộng Hòa, twin records)', at: LatLng(10.80290, 106.63890), kmh: 60),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Loads the layer, or marks the test SKIPPED on the CI stub.
  Future<bool> ready() async {
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped(
        'speed-limit assets are stubs here (see tool/stub_assets.sh)',
      );
      return false;
    }
    return true;
  }

  for (final s in _samples) {
    test('the limit chain answers at ${s.what}', () async {
      if (!await ready()) return;
      final hit = await lookupSpeedLimit(s.at);
      // ignore: avoid_print
      print(
        '${s.what}: lookupSpeedLimit -> '
        '${hit == null ? 'null' : 'limit=${hit.limit} source=${hit.source} '
            'street=${hit.streetName} segmentId=${hit.segmentId}'}',
      );
      expect(
        hit,
        isNotNull,
        reason: 'the pack holds ${s.kmh} km/h here — the chain found nothing',
      );
      expect(hit!.limit, s.kmh);
    });
  }

  test('the car\'s heading picks the carriageway, and never blanks the answer',
      () async {
    if (!await ready()) return;
    // This stretch carries TWO records of one road (one per direction), 50 and
    // 60. Without a heading the nearest wins (60); with a heading the record
    // matching the direction of travel wins (50). Either way the chain must
    // ANSWER — a heading must not blank the dial.
    final at = _samples[2].at;
    final north = await lookupSpeedLimit(at, headingDeg: 5);
    final south = await lookupSpeedLimit(at, headingDeg: 185);
    final none = await lookupSpeedLimit(at);
    // ignore: avoid_print
    print('heading north=${north?.limit} south=${south?.limit} '
        'none=${none?.limit}');
    expect(north, isNotNull);
    expect(south, isNotNull);
    expect(none, isNotNull);
    expect(north!.limit, 50);
    expect(south!.limit, 50);
    expect(none!.limit, 60);
  });

  test('expectStreet: the road on screen, spelled QL1, still answers', () async {
    if (!await ready()) return;
    // The page passes the street it displays. On this route that street is
    // 'QL1' — and `streetNameMatches('QL1','QL1')` returned FALSE (a 3-char
    // single token failed the "min 4 chars" rule), so every posted limit on the
    // route was dropped and the dial read '-' for 1,686 km.
    final at = _samples[2].at;
    final on = await lookupSpeedLimit(at, expectStreet: 'QL1');
    final other = await lookupSpeedLimit(at, expectStreet: 'Nguyễn Văn Cừ');
    // ignore: avoid_print
    print('expectStreet QL1 -> ${on?.limit}, another road -> ${other?.limit}');
    expect(on?.limit, 60, reason: 'a name must match itself, however short');
    expect(other, isNull, reason: 'a different street must not supply it');
  });
}
