/// Sign announcement PRIORITY — who gets the voice when several signs compete.
///
/// Regression guard for the starvation bug measured on the 22-trip batch
/// (`tool/resident_misses.py`): under the old "nearest announceable sign wins"
/// rule a built-up (khu dân cư) boundary could be blocked forever by a nearer
/// minor plate, and 27 of 84 built-up zones had no callout within 3 km.
///
///   resident_trips_test.dart   — the phrases that ARE spoken
///   sign_priority_test.dart    — which sign is chosen to speak them
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/pages/navigation/navigation_page.dart'
    show
        announcedSignKinds,
        signAnnounceTier,
        signCalloutSig;
import 'package:navbridge/services/offline_road_signs.dart';

/// The kinds the whole design rests on. If a refactor drops one of these the
/// driver stops hearing it — which is exactly how the boundary went missing.
const _mustAnnounce = <RoadSignKind>[
  RoadSignKind.populated,
  RoadSignKind.populatedEnd,
  RoadSignKind.stop,
  RoadSignKind.giveWay,
  RoadSignKind.signal,
  RoadSignKind.noPassing,
  RoadSignKind.noUTurn,
  RoadSignKind.noLeftTurn,
  RoadSignKind.oneWay,
];

void main() {
  group('the announced-kind set', () {
    test('carries every kind the driver is promised', () {
      for (final k in _mustAnnounce) {
        expect(announcedSignKinds.contains(k), isTrue,
            reason: '$k is announced in the field but missing from the set');
      }
    });

    test('never announces a speed sign — those are map-only', () {
      // The limit is spoken by the limit path, with the vehicle cap applied.
      // A second "Giới hạn X" from here would speak an uncapped number.
      expect(announcedSignKinds.contains(RoadSignKind.speed), isFalse);
    });

    test('a zone boundary is announced', () {
      expect(announcedSignKinds.contains(RoadSignKind.populated), isTrue);
      expect(announcedSignKinds.contains(RoadSignKind.populatedEnd), isTrue);
    });
  });

  group('signAnnounceTier — lower wins', () {
    test('the built-up boundary outranks EVERY other announced kind', () {
      final boundary = signAnnounceTier(RoadSignKind.populated);
      expect(boundary, 0);
      expect(signAnnounceTier(RoadSignKind.populatedEnd), 0);
      for (final k in announcedSignKinds) {
        expect(signAnnounceTier(k), greaterThanOrEqualTo(boundary),
            reason: '$k must not outrank the khu dân cư boundary');
      }
    });

    test('the "obey now" set outranks turn and lane plates', () {
      const obey = [
        RoadSignKind.stop,
        RoadSignKind.giveWay,
        RoadSignKind.signal,
        RoadSignKind.noPassing,
        RoadSignKind.noPassingEnd,
      ];
      const plates = [
        RoadSignKind.noParking,
        RoadSignKind.noLeftTurn,
        RoadSignKind.noRightTurn,
        RoadSignKind.onlyStraight,
        RoadSignKind.reservedLane,
        RoadSignKind.oneWay,
      ];
      for (final o in obey) {
        for (final p in plates) {
          expect(signAnnounceTier(o), lessThan(signAnnounceTier(p)),
              reason: '$o must win the voice over $p');
        }
      }
    });

    test('the boundary beats a nearer minor plate — the starvation case', () {
      // The bug: a no-parking plate 20 m ahead was re-chosen every fix and its
      // dedupe hit returned early, so a boundary 300 m ahead never spoke.
      // Tier-first means distance can no longer decide this.
      final boundaryFar = signAnnounceTier(RoadSignKind.populated); // 300 m
      final plateNear = signAnnounceTier(RoadSignKind.noParking); // 20 m
      expect(boundaryFar, lessThan(plateNear));
    });
  });

  group('signCalloutSig — far/near, never twice', () {
    RoadSign at(double lat, double lng, RoadSignKind kind) => RoadSign(
          name: '',
          kind: kind,
          lat: lat,
          lng: lng,
        );

    test('the same sign differs between the far and near callout', () {
      final s = at(20.85792, 106.65123, RoadSignKind.populated);
      expect(signCalloutSig(s, near: false),
          isNot(signCalloutSig(s, near: true)));
    });

    test('two different signs never share a key', () {
      final a = at(20.85792, 106.65123, RoadSignKind.populated);
      final b = at(20.85793, 106.65123, RoadSignKind.populated);
      expect(signCalloutSig(a, near: false),
          isNot(signCalloutSig(b, near: false)));
    });

    test('a start and an end boundary at one point stay distinct', () {
      // They are different calls; a shared key would swallow "Hết khu dân cư".
      final a = at(20.85792, 106.65123, RoadSignKind.populated);
      final b = at(20.85792, 106.65123, RoadSignKind.populatedEnd);
      expect(signCalloutSig(a, near: false),
          isNot(signCalloutSig(b, near: false)));
    });

    test('the key is stable — the same sign re-reads identically', () {
      final s = at(20.85792, 106.65123, RoadSignKind.populated);
      expect(signCalloutSig(s, near: false),
          signCalloutSig(s, near: false));
    });
  });
}
