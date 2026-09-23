/// Locks the sign-precision guard against the bundled index.
///
/// Why: whole KINDS in `vietnam_signs.json` carry a 0.001° (≈111 m) coordinate
/// grid — `only_left` 6/6, `only_right` 11/11, `end_prohibitions` 270/350,
/// `no_u_turn` 94/228, `no_left_turn` 122/353, `speed` 4,168/20,753. The app
/// SPEAKS those turn signs ("Cấm rẽ trái sắp tới"), so a sign ±55 m off warns
/// on the wrong street; of the 8 turn signs within 1.5 km of the Bàu Cát
/// corridor, 5 had no second street (2 had no street at all) within 30 m.
/// `signCoordsAreUsable` drops them at load, and this test pins both the rule
/// and the real counts, so a regenerated asset that fixes the coordinates will
/// change these numbers loudly instead of silently.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/services/offline_road_signs.dart';

void main() {
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
}
