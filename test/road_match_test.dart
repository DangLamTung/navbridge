/// Road-name decision: the route as a veto, plus change hysteresis.
///
/// The numbers these encode come from auditing the 2026-09-21 17:33 drive
/// against OSM: the matcher named a road that was not the nearest way on 48% of
/// fixes (median 119 m away, correct way 4 m), and at one junction the name
/// alternated every second for 17 s.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/core/road_match.dart';

void main() {
  group('roadKey / sameRoad', () {
    test('ignores case, diacritics, punctuation and spacing', () {
      expect(roadKey('Đường 30 Tháng 4'), roadKey('duong 30 thang 4'));
      expect(roadKey('Lũy Bán Bích'), roadKey('Luy Ban Bich'));
      expect(roadKey('Trương Công Định'), 'truongcongdinh');
    });

    test('treats a named alley as the same street as its parent', () {
      expect(sameRoad('Vườn Lài', 'Hẻm 4 Vườn Lài'), isTrue);
      expect(sameRoad('Trường Chinh', 'Trương Công Định'), isFalse);
      expect(sameRoad('', 'Lũy Bán Bích'), isFalse);
    });
  });

  group('pickRoadName — the route as a veto', () {
    test('keeps the route street when the match is off-route', () {
      // The 17:35 case: the match said 'Trường Chinh' (80 m away) while the car
      // was on 'Trương Công Định' (3 m) — the route knew which one it was on.
      expect(
        pickRoadName(
          current: 'Trương Công Định',
          candidate: 'Trường Chinh',
          candidateOnRoute: false,
          currentOnRoute: true,
        ),
        'Trương Công Định',
      );
    });

    test('accepts the match when the route agrees', () {
      expect(
        pickRoadName(
          current: 'Lũy Bán Bích',
          candidate: 'Đường 30 Tháng 4',
          candidateOnRoute: true,
          currentOnRoute: true,
        ),
        'Đường 30 Tháng 4',
      );
    });

    test('trusts the match when neither name is on the route', () {
      expect(
        pickRoadName(
          current: 'Hẻm 8 Yên Đổ',
          candidate: 'Hẻm 4 Vườn Lài',
          candidateOnRoute: false,
          currentOnRoute: false,
        ),
        'Hẻm 4 Vườn Lài',
      );
    });

    test('keeps the current name when the match has none', () {
      expect(
        pickRoadName(
          current: 'Ấp Bắc',
          candidate: '',
          candidateOnRoute: false,
          currentOnRoute: true,
        ),
        'Ấp Bắc',
      );
    });
  });

  group('RoadNameHysteresis', () {
    test('a single odd fix cannot relabel the road', () {
      final h = RoadNameHysteresis();
      expect(
        h.accept(current: 'Ấp Bắc', candidate: 'Lũy Bán Bích', movedM: 4),
        isFalse,
      );
      // …and the flip-flop at the junction never publishes either.
      expect(
        h.accept(current: 'Ấp Bắc', candidate: 'Ấp Bắc', movedM: 4),
        isFalse,
      );
      expect(
        h.accept(current: 'Ấp Bắc', candidate: 'Lũy Bán Bích', movedM: 4),
        isFalse,
      );
    });

    test('a real change is published once it repeats', () {
      final h = RoadNameHysteresis();
      h.accept(current: 'Ấp Bắc', candidate: 'Trường Chinh', movedM: 9);
      expect(
        h.accept(current: 'Ấp Bắc', candidate: 'Trường Chinh', movedM: 9),
        isTrue,
      );
    });

    test('travel forces a change through after 30 m', () {
      final h = RoadNameHysteresis();
      var published = false;
      // A slow, steady change: 6 fixes × 6 m = 36 m, never twice in a row.
      for (var i = 0; i < 8 && !published; i++) {
        published = h.accept(
          current: 'Ấp Bắc',
          candidate: 'Trường Chinh',
          movedM: 6,
        );
      }
      expect(published, isTrue);
    });

    test('returning to the current name clears the pending change', () {
      final h = RoadNameHysteresis();
      h.accept(current: 'Ấp Bắc', candidate: 'Lũy Bán Bích', movedM: 5);
      expect(h.confirmations, 1);
      h.accept(current: 'Ấp Bắc', candidate: 'Ấp Bắc', movedM: 5);
      expect(h.pending, isNull);
      expect(h.confirmations, 0);
    });
  });
}
