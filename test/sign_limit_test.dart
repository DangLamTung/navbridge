/// Regression test for the 09-18 drive: a speed sign belonging to the street
/// the car was about to join was applied 400 m early and never released, so a
/// 4.5 km drive ran at 60 km/h on roads whose own posted value was 50.
///
/// The real numbers from that drive: sign 60 km/h at 350 m ahead, the car on
/// Vườn Lài, the sign's own segment being Lũy Bán Bích.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/sign_limit.dart';

void main() {
  group('signLimitInForce', () {
    test('a sign ahead is a preview, not the limit', () {
      // The 09-18 failure: 60 km/h sign 350 m ahead while on Vườn Lài.
      expect(
        signLimitInForce(
          signValue: 60,
          signAheadM: 350,
          signRoad: 'Vườn Lài',
          currentRoad: 'Vườn Lài',
        ),
        isFalse,
        reason: 'the road value must stand until the car is at the sign',
      );
    });

    test('it becomes the limit once reached', () {
      expect(
        signLimitInForce(
          signValue: 60,
          signAheadM: 0,
          signRoad: 'Vườn Lài',
          currentRoad: 'Vườn Lài',
        ),
        isTrue,
      );
    });

    test('released after turning onto another road', () {
      expect(
        signLimitInForce(
          signValue: 60,
          signAheadM: 0,
          signRoad: 'Lũy Bán Bích',
          currentRoad: 'Vườn Lài',
        ),
        isFalse,
        reason: 'a 60 posted on Lũy Bán Bích must not govern Vườn Lài',
      );
    });

    test('unknown road is trusted only where the car stands', () {
      // Adopted before the first road lookup: still in force once reached...
      expect(
        signLimitInForce(
          signValue: 60,
          signAheadM: 0,
          signRoad: null,
          currentRoad: null,
        ),
        isTrue,
      );
      // ...and released the moment the road changes (the caller re-binds the
      // name at that point, so `currentRoad` differs).
      expect(
        signLimitInForce(
          signValue: 60,
          signAheadM: 0,
          signRoad: null,
          currentRoad: 'Vườn Lài',
        ),
        isTrue,
        reason:
            'null road is trusted; the caller binds a name when it knows '
            'one, after which a change is detected',
      );
    });

    test('no sign, or a nonsense value, is never in force', () {
      expect(
        signLimitInForce(
          signValue: null,
          signAheadM: 0,
          signRoad: 'Vườn Lài',
          currentRoad: 'Vườn Lài',
        ),
        isFalse,
      );
      expect(
        signLimitInForce(
          signValue: 0,
          signAheadM: 0,
          signRoad: 'Vườn Lài',
          currentRoad: 'Vườn Lài',
        ),
        isFalse,
      );
    });
  });

  test('the segment layer is authority: a sign cannot RAISE it', () {
    // The 2026-09-20 case: three VietMap 60 signs standing on Lũy Bán Bích
    // (their own segment says 60) were applied to Tân Thành / Vườn Lài,
    // whose segment says 50 — 166 fixes of the chip reading 60 on a 50 road.
    expect(
      signLimitInForce(
        signValue: 60,
        signAheadM: 0,
        signRoad: 'Tân Thành',
        currentRoad: 'Tân Thành',
        layerKmh: 50,
      ),
      isFalse,
      reason: 'the layer says 50, so a 60 sign must not lift it',
    );
  });

  test('but a sign that TIGHTENS the layer still applies', () {
    expect(
      signLimitInForce(
        signValue: 40,
        signAheadM: 0,
        signRoad: 'Tân Thành',
        currentRoad: 'Tân Thành',
        layerKmh: 50,
      ),
      isTrue,
      reason: 'a genuine 40 zone must still bite',
    );
  });

  test('with no layer value the sign is judged as before', () {
    expect(
      signLimitInForce(
        signValue: 60,
        signAheadM: 0,
        signRoad: 'Tân Thành',
        currentRoad: 'Tân Thành',
      ),
      isTrue,
    );
  });
}
