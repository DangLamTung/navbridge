import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_speed_limits.dart';

/// REAL-TRIP tests: the actual bundled limit layer, on coordinates from the
/// 2026-09-14 HCMC drive, where each point sits within a few metres of a crawled
/// Waze segment.
///
/// These need `assets/offline_map/waze_segments.bin` (28 MB, NOT in git — see
/// `tool/stub_assets.sh`), so they live on the FUNCTION line in `test/func/`
/// and are run explicitly:
///
///   unit:  flutter test test/unit
///   func:  flutter test test/func
///   both:  tool/check.sh
///
/// With the CI stub packs every test here reports SKIPPED rather than passing
/// silently: the printed `limit=… source=… street=… segmentId=…` lines are the
/// evidence that a run actually resolved real segments.
const _luyBanBich = LatLng(10.79571, 106.63825); // divided road → 60
const _auCo = LatLng(10.79697, 106.63789); // two-way, no median → 50
const _apBac = LatLng(10.80073, 106.64134); // residential → 50
const _pacific = LatLng(5.0, 160.0); // nothing anywhere near

/// Diacritic-insensitive fold, so `Âu Cơ` matches a name stored either way.
String _fold(String s) {
  final lower = s.toLowerCase().replaceAll('đ', 'd');
  const map = {
    'à': 'a', 'á': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a', 'ă': 'a', 'ằ': 'a',
    'ắ': 'a', 'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a', 'â': 'a', 'ầ': 'a', 'ấ': 'a',
    'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a', 'è': 'e', 'é': 'e', 'ẻ': 'e', 'ẽ': 'e',
    'ẹ': 'e', 'ê': 'e', 'ề': 'e', 'ế': 'e', 'ể': 'e', 'ễ': 'e', 'ệ': 'e',
    'ì': 'i', 'í': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i', 'ò': 'o', 'ó': 'o',
    'ỏ': 'o', 'õ': 'o', 'ọ': 'o', 'ô': 'o', 'ồ': 'o', 'ố': 'o', 'ổ': 'o',
    'ỗ': 'o', 'ộ': 'o', 'ơ': 'o', 'ờ': 'o', 'ớ': 'o', 'ở': 'o', 'ỡ': 'o',
    'ợ': 'o', 'ù': 'u', 'ú': 'u', 'ủ': 'u', 'ũ': 'u', 'ụ': 'u', 'ư': 'u',
    'ừ': 'u', 'ứ': 'u', 'ử': 'u', 'ữ': 'u', 'ự': 'u', 'ỳ': 'y', 'ý': 'y',
    'ỷ': 'y', 'ỹ': 'y', 'ỵ': 'y',
  };
  final buf = StringBuffer();
  for (final ch in lower.split('')) {
    buf.write(map[ch] ?? ch);
  }
  return buf.toString();
}

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

  test('the segment tier reports limit + source + street + id together',
      () async {
    if (!await ready()) return;

    for (final (point, kmh, street) in [
      // (measured: limit / source / street / segmentId, printed below)
      (_luyBanBich, 60, 'Lũy Bán Bích'),
      // `test/offline_speed_limits_test.dart` describes this stretch as Âu Cơ
      // (the VALUE 50 is right), but the segment that actually wins here is
      // "Trần Tấn" — the name is only kept honest in the app because
      // `nav_gps` passes `expectStreet` and the token veto drops a crossing
      // street's name. Without the veto the chip would read Trần Tấn on Âu Cơ.
      (_auCo, 50, 'Trần Tấn'),
      (_apBac, 50, 'Ấp Bắc'),
    ]) {
      final r = await lookupSpeedLimit(point);
      // ignore: avoid_print
      print('lookupSpeedLimit($point) -> limit=${r?.limit} source=${r?.source} '
          'street=${r?.streetName} segmentId=${r?.segmentId}');
      expect(r, isNotNull, reason: 'no result at $point');
      expect(r!.source, 'segment', reason: 'segment layer should win at $point');
      expect(r.limit, kmh);
      expect(r.segmentId, isNotNull);
      expect(r.streetName, isNotNull);
      expect(r.streetName!.trim(), isNotEmpty);
      expect(
        _fold(r.streetName!),
        contains(_fold(street)),
        reason: 'named "${r.streetName}" at $point',
      );
    }
  });

  test('a lookup in between cannot rewrite an earlier result', () async {
    if (!await ready()) return;

    final first = await lookupSpeedLimit(_auCo);
    final second = await lookupSpeedLimit(_luyBanBich);
    expect(first, isNotNull);
    expect(second, isNotNull);
    // Two DIFFERENT roads: if the lookups shared state, one of these pairs
    // would mix limit and street.
    expect(first!.source, 'segment');
    expect(second!.source, 'segment');
    expect(_fold(first.streetName!), isNot(_fold(second.streetName!)));
    expect(first.segmentId, isNot(second.segmentId));

    // Same point again, after the other lookup: identical answer.
    final again = await lookupSpeedLimit(_auCo);
    expect(again!.limit, first.limit);
    expect(again.streetName, first.streetName);
    expect(again.segmentId, first.segmentId);
    expect(again.source, first.source);
  });

  test('the legacy wrapper exposes exactly the result it returned', () async {
    if (!await ready()) return;

    final direct = await lookupSpeedLimit(_apBac);
    expect(direct, isNotNull);
    final lim = await speedLimitAt(_apBac);
    expect(lim, direct!.limit);
    expect(lastLimitLayer(), direct.source);
    expect(lastWazeSegmentId(), direct.segmentId);
    expect(lastWazeStreetName(), direct.streetName);
  });

  test('a miss clears the wrapper globals instead of leaving them stale',
      () async {
    if (!await ready()) return;

    // Establish real state first, so that the clearing below is what is tested.
    final hit = await lookupSpeedLimit(_auCo);
    expect(hit, isNotNull);
    expect(hit!.segmentId, isNotNull);
    expect(lastWazeSegmentId(), isNot(-1));

    expect(await lookupSpeedLimit(_pacific), isNull);
    expect(await speedLimitAt(_pacific), isNull);
    expect(lastLimitLayer(), isNull);
    expect(lastWazeSegmentId(), -1);
    expect(lastWazeStreetName(), isNull);
  });
}
