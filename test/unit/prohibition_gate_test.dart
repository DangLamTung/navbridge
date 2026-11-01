/// CẤM VƯỢT is a STATE, not a series of plates.
///
/// The packs repeat P.125 every couple of kilometres along one ban and post
/// "cấm vượt" 1 m from "hết cấm vượt" at the same post, so a policy that speaks
/// every plate reads three sentences in 2 s (measured 2026-10-25, km 40,6 /
/// 41,5 / 42,2) or two identical ones 540 m apart (measured 2026-10-29, 176 km
/// Bảo Lộc → Sài Gòn). The rule below is what the driver hears, and it also
/// keeps a prohibition clear of the khu dân cư sentence spoken at the same
/// junction.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/sign_limit.dart';

void main() {
  group('prohibitionSuppressed', () {
    test('the first ban is announced', () {
      expect(
        prohibitionSuppressed(
          startsBan: true,
          bannedNow: false,
          oppositeNear: false,
          zoneNear: false,
        ),
        isFalse,
      );
    });

    test('a ban already in force is not repeated', () {
      expect(
        prohibitionSuppressed(
          startsBan: true,
          bannedNow: true,
          oppositeNear: false,
          zoneNear: false,
        ),
        isTrue,
        reason: '540 m / 2 km later — same ban, nothing new to say',
      );
    });

    test('the end of an announced ban IS announced', () {
      expect(
        prohibitionSuppressed(
          startsBan: false,
          bannedNow: true,
          oppositeNear: false,
          zoneNear: false,
        ),
        isFalse,
      );
    });

    test('an end with no ban announced says nothing', () {
      expect(
        prohibitionSuppressed(
          startsBan: false,
          bannedNow: false,
          oppositeNear: false,
          zoneNear: false,
        ),
        isTrue,
      );
    });

    test('the opposite plate at the same post does not flip the ban', () {
      expect(
        prohibitionSuppressed(
          startsBan: false,
          bannedNow: true,
          oppositeNear: true,
          zoneNear: false,
        ),
        isTrue,
      );
    });

    test('a built-up boundary sentence wins the junction', () {
      expect(
        prohibitionSuppressed(
          startsBan: true,
          bannedNow: false,
          oppositeNear: false,
          zoneNear: true,
        ),
        isTrue,
      );
    });

    test('the junction hold is shorter than the flip guard', () {
      expect(kZoneProhibitionGapM, lessThan(kProhibitionFlipM));
    });
  });
  group('limited-access roads', () {
    test('a freeway, its ramp and a toll plaza are never a town', () {
      expect(isLimitedAccessRoad('CT HCM-Long Thành-Dầu Giây'), isTrue);
      expect(isLimitedAccessRoad('CT01 > Long Thành / Dầu Giây'), isTrue);
      expect(isLimitedAccessRoad('Trạm thu phí Dầu Giây'), isTrue);
      expect(isLimitedAccessRoad('> Dầu Giây'), isTrue);
      expect(isLimitedAccessRoad('Cao tốc Trung Lương'), isTrue);
      // WME roadType: 3 = freeway, 4 = ramp — even with no name at all.
      expect(isLimitedAccessRoad(null, roadClass: 3), isTrue);
      expect(isLimitedAccessRoad('', roadClass: 4), isTrue);
    });

    test('an ordinary road keeps its built-up verdict', () {
      expect(isLimitedAccessRoad('Quốc lộ 20'), isFalse);
      expect(isLimitedAccessRoad('QL1', roadClass: 6), isFalse);
      expect(isLimitedAccessRoad('Mai Chí Thọ'), isFalse);
      expect(isLimitedAccessRoad(null), isFalse);
    });

    test('the mixed lane beside an expressway is not evidence either way', () {
      expect(isMixedLane('Mai Chí Thọ (Làn hỗn hợp)'), isTrue);
      expect(isMixedLane('Mai Chí Thọ'), isFalse);
    });
  });
}
