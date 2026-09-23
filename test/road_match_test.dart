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

  group('sameRoadSpelling', () {
    test('ignores case, diacritics and punctuation only', () {
      // 2026-09-22 20:54: the label churned Cộng Hòa ⇄ Cộng Hoà for 54 s.
      expect(sameRoadSpelling('Cộng Hòa', 'Cộng Hoà'), isTrue);
      expect(sameRoadSpelling('Ni Sư Huỳnh Liên', 'Ni sư Huỳnh Liên'), isTrue);
      expect(sameRoadSpelling('Lũy Bán Bích', 'Luy Ban Bich'), isTrue);
    });

    test('keeps a side street distinct from the road it hangs off', () {
      // sameRoad() treats containment as one road (used for the route veto),
      // but a name change must still be able to show the alley.
      expect(sameRoad('Hẻm 62/1 Trương Công Định', 'Trương Công Định'), isTrue);
      expect(sameRoadSpelling('Hẻm 62/1 Trương Công Định', 'Trương Công Định'),
          isFalse);
    });

    test('empty names never match', () {
      expect(sameRoadSpelling('', ''), isFalse);
      expect(sameRoadSpelling('', 'Cộng Hòa'), isFalse);
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

    test('a variant spelling of the current name is not a change', () {
      final h = RoadNameHysteresis();
      for (var i = 0; i < 5; i++) {
        expect(
          h.accept(current: 'Cộng Hòa', candidate: 'Cộng Hoà', movedM: 10),
          isFalse,
        );
      }
      expect(h.pending, isNull);
    });

    test('two writers on one fix are ONE observation', () {
      // The graph refresh and the layer correction both publish on every fix;
      // if both propose the same name, the change must still need two fixes.
      final h = RoadNameHysteresis();
      final t0 = DateTime(2026, 9, 22, 18, 5, 40);
      expect(
        h.accept(
          current: 'Cộng Hòa',
          candidate: 'Cầu vượt Hoàng Hoa Thám',
          movedM: 12,
          at: t0,
        ),
        isFalse,
        reason: 'first writer on fix 1',
      );
      expect(
        h.accept(
          current: 'Cộng Hòa',
          candidate: 'Cầu vượt Hoàng Hoa Thám',
          movedM: 0,
          at: t0.add(const Duration(milliseconds: 40)),
        ),
        isFalse,
        reason: 'second writer on the SAME fix must not confirm it',
      );
      expect(h.confirmations, 1);
      // The next fix, ~1 s later: that IS a second observation.
      expect(
        h.accept(
          current: 'Cộng Hòa',
          candidate: 'Cầu vượt Hoàng Hoa Thám',
          movedM: 14,
          at: t0.add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('alternating names every fix are never accepted', () {
      // The 2026-09-22 18:05 pattern at the Hoàng Hoa Thám flyover: 28
      // oscillations. Each name is proposed by both writers on its own fix.
      final h = RoadNameHysteresis();
      var t = DateTime(2026, 9, 22, 18, 5, 27);
      var changes = 0;
      const a = 'Cộng Hòa';
      const b = 'Cầu vượt Hoàng Hoa Thám';
      for (var fix = 0; fix < 40; fix++) {
        final cand = fix.isEven ? b : a;
        for (var w = 0; w < 2; w++) {
          if (h.accept(
            current: a,
            candidate: cand,
            movedM: w == 0 ? 15 : 0,
            at: t.add(Duration(milliseconds: 30 * w)),
          )) {
            changes++;
          }
        }
        t = t.add(const Duration(milliseconds: 1000));
      }
      expect(changes, 0);
    });
  });
  group('postedLimitMatchesName', () {
    test('accepts the segment whose street we are displaying', () {
      expect(postedLimitMatchesName('Lũy Bán Bích', 'Lũy Bán Bích'), isTrue);
      expect(postedLimitMatchesName('Luy Ban Bich', 'Lũy Bán Bích'), isTrue);
    });

    test('rejects a crossing street\'s value', () {
      // 17:40:16 of the 2026-09-21 drive: the display said Lũy Bán Bích while
      // the winning segment was the crossing Độc Lập (50 km/h).
      expect(postedLimitMatchesName('Độc Lập', 'Lũy Bán Bích'), isFalse);
      expect(postedLimitMatchesName('Lũy Bán Bích', 'Thống Nhất'), isFalse);
    });

    test('an unnamed segment carries no evidence, so it is allowed', () {
      expect(postedLimitMatchesName(null, 'Lũy Bán Bích'), isTrue);
      expect(postedLimitMatchesName('', 'Lũy Bán Bích'), isTrue);
    });

    test('an unnamed displayed road is not overruled', () {
      expect(postedLimitMatchesName('Độc Lập', ''), isTrue);
    });
  });
}
