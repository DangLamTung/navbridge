/// Which posted-limit segment the app trusts when several are in range.
///
/// Real case (2026-09-21 17:45, HCMC): the car drove north up Đường 30 Tháng 4
/// through its junction with Lũy Bán Bích. With 15-20 m GPS accuracy the
/// nearest Waze segment alternated between the two streets every fix, so the
/// street chip — and the voice, which reads the chip's name and the same
/// segment's limit — said "Lũy Bán Bích" while the car was on 30 Tháng 4.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/services/offline_speed_limits.dart';

/// (segment, distance, bearing) as the lookup builds them.
List<(int, double, double)> _cands(List<(double, double)> dbrg) => [
  for (var i = 0; i < dbrg.length; i++) (i, dbrg[i].$1, dbrg[i].$2),
];

void main() {
  group('segmentLineAngle', () {
    test('is 0 along the line and 90 across it', () {
      expect(segmentLineAngle(21, 21), closeTo(0, 0.01));
      expect(segmentLineAngle(21, 90), closeTo(69, 0.01));
      expect(segmentLineAngle(0, 90), closeTo(90, 0.01));
    });

    test('ignores direction: the opposite carriageway is the same road', () {
      expect(segmentLineAngle(21, 201), closeTo(0, 0.01));
      expect(segmentLineAngle(200, 20), closeTo(0, 0.01));
    });

    test('is 0 when the heading is unknown (no signal to judge with)', () {
      expect(segmentLineAngle(null, 90), 0);
    });
  });

  group('segmentScore', () {
    test('a segment across the path is pushed out of range', () {
      // 2 m away but perpendicular → scores past the 25 m range.
      expect(segmentScore(2, 90, 0, 25), greaterThan(25));
      // 20 m away and aligned → keeps its distance.
      expect(segmentScore(20, 0, 0, 25), 20);
    });

    test('without a heading it is plain nearest-wins', () {
      expect(segmentScore(2, 90, null, 25), 2);
    });
  });

  group('pickSegmentCandidate — the Đường 30 Tháng 4 junction', () {
    test('prefers the aligned road over a nearer crossing street', () {
      // Heading 21° (NNE, riding 30 Tháng 4). Lũy Bán Bích runs ~E-W (bearing
      // 110) and its segment is a metre closer.
      final cands = _cands([(3.0, 110.0), (4.0, 25.0)]);
      expect(pickSegmentCandidate(cands, 21, 25), 1);
      // …and the crossing street wins nothing even at 1 m.
      final closer = _cands([(1.0, 110.0), (12.0, 25.0)]);
      expect(pickSegmentCandidate(closer, 21, 25), 1);
    });

    test('falls back to the nearest segment when nothing is aligned', () {
      // Stopped mid-turn, or on a road the layer does not name.
      final cands = _cands([(8.0, 100.0), (14.0, 130.0)]);
      expect(pickSegmentCandidate(cands, 15, 25), 0);
    });

    test('returns -1 when every candidate is out of range', () {
      final cands = _cands([(30.0, 20.0), (40.0, 25.0)]);
      expect(pickSegmentCandidate(cands, 21, 25), -1);
    });

    test('a nearer crossing segment does not beat an aligned one in range', () {
      // Worst case from the drive: 15 m accuracy, both segments under the car.
      final cands = _cands([(2.0, 90.0), (24.0, 22.0)]);
      final win = pickSegmentCandidate(cands, 21, 25);
      expect(cands[win].$2, 24.0, reason: 'the crossing street must not win');
    });

    test('empty candidates', () {
      expect(pickSegmentCandidate(const [], 21, 25), -1);
    });
  });
}
