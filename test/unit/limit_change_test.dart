/// The driver's speed limit CHANGED — do they get told, once, with the right
/// number, and not again for the same value?
///
/// The announcement is the only way the driver learns a new limit while
/// riding: the chip is on an E-ink panel mounted low, and the whole overspeed
/// warning is keyed off the same value. So the timing contract in
/// `lib/core/limit_change.dart` is a driver-facing feature, not plumbing — it
/// was extracted from `nav_voice.dart` precisely so it could be tested without
/// a widget (a boundary crossed at 60 km/h is past in a second, and road info
/// flickers between two records of the same street).
///
///   flutter test test/unit/limit_change_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/limit_change.dart';

/// A clock the test drives by hand, so `stableFor` / `cooldown` are exercised
/// as real elapsed time instead of sleeps.
class _Clock {
  DateTime t = DateTime.utc(2026, 9, 28, 8, 0, 0);
  void advance(Duration d) => t = t.add(d);
  void advanceS(double s) => advance(Duration(milliseconds: (s * 1000).round()));
}

/// Feed [limit] on a fix every second for [seconds] and return the values the
/// announcer said to speak, in order.
List<int> _ride(LimitChangeAnnouncer a, _Clock c, int limit, double seconds) {
  final said = <int>[];
  for (var i = 0; i < seconds.round(); i++) {
    c.advanceS(1);
    final v = a.announce(limit, c.t);
    if (v != null) said.add(v);
  }
  return said;
}

void main() {
  group('the speed-change announcement', () {
    test('a limit that holds is announced exactly once', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // Riding a 50 road for 10 s: one announcement, then silence.
      final said = _ride(a, c, 50, 10);
      expect(said, [50], reason: 'the same limit is never repeated');
      expect(a.lastAnnounced, 50);
    });

    test('nothing is said until the new limit has been stable 2 s', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // First fix arms the window; it cannot speak on the same fix.
      expect(a.announce(50, c.t), isNull);
      c.advanceS(1);
      expect(a.announce(50, c.t), isNull,
          reason: '1 s is not yet stable — road info flickers');
      c.advanceS(1);
      expect(a.announce(50, c.t), 50, reason: '2 s of the same value');
    });

    test('a flicker is swallowed: 50 → 60 → 50 announces only 50', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // Two Waze records of one street disagree, so the value alternates for a
      // few fixes. A per-fix announcer would say "60" and "50" seconds apart.
      expect(a.announce(50, c.t), isNull);
      c.advanceS(1);
      expect(a.announce(60, c.t), isNull,
          reason: 'the candidate changed — the window restarts');
      c.advanceS(1);
      expect(a.announce(50, c.t), isNull,
          reason: 'back to 50, but its window was restarted');
      c.advanceS(1);
      expect(a.announce(50, c.t), isNull, reason: 'only 1 s of 50 again');
      c.advanceS(1);
      expect(a.announce(50, c.t), 50, reason: 'now it has held 2 s');
    });

    test('a genuine change is announced, and the old value again later', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      expect(_ride(a, c, 50, 5), [50]);
      // Crossing into a 60 zone: announced after the stability window, not on
      // the fix the value changed.
      expect(a.announce(60, c.t), isNull);
      c.advanceS(2);
      expect(a.announce(60, c.t), 60);
      // Leaving town: back down to 50 — a NEW announcement, because the value
      // differs from the last one announced.
      c.advanceS(2);
      expect(a.announce(50, c.t), isNull);
      c.advanceS(2);
      expect(a.announce(50, c.t), 50);
    });

    test('the cooldown stops a chain of short segments machine-gunning', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // 50 announced at t=2 s.
      expect(_ride(a, c, 50, 3), [50]);
      // A 60 segment that lasts only 2 s: stable, but inside the 4 s cooldown,
      // so it must stay silent rather than interrupt.
      expect(a.announce(60, c.t), isNull);
      c.advanceS(2);
      expect(a.announce(60, c.t), isNull,
          reason: 'stable, but the cooldown from the 50 has not elapsed');
      // Once the cooldown has passed AND the value is stable, it speaks.
      c.advanceS(3);
      expect(a.announce(60, c.t), 60);
    });

    test('a value just spoken by the turn callout is not said twice', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // The maneuver callout already ended "… Tốc độ tối đa 50 km/h."
      a.noteSpoken(50, c.t);
      c.advanceS(3);
      expect(a.announce(50, c.t), isNull,
          reason: 'the same number in a second sentence is the same fact twice');
      // …and it must not re-arm and fire later either: the fix that swallowed
      // it settles the value, so the next fixes stay quiet.
      c.advanceS(2);
      expect(a.announce(50, c.t), isNull);
      expect(a.lastAnnounced, 50, reason: 'remembered, so it will not re-arm');
      // A DIFFERENT limit is still announced — the guard is value-specific.
      expect(a.announce(60, c.t), isNull);
      c.advanceS(3);
      expect(a.announce(60, c.t), 60);
    });

    test('the note only covers the value said, and only for 45 s', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      a.noteSpoken(50, c.t);
      expect(a.spokenRecently(50, c.t), isTrue);
      expect(a.spokenRecently(60, c.t), isFalse,
          reason: 'another value was never said');
      c.advanceS(44);
      expect(a.spokenRecently(50, c.t), isTrue);
      c.advanceS(2);
      expect(a.spokenRecently(50, c.t), isFalse,
          reason: 'the note expires — a limit spoken 45 s ago may be said again');
    });

    test('no limit known means no announcement', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // 0 is the app's "unknown" for a limit — saying nothing is the only safe
      // option, and it must not arm a window that later fires on a real value.
      expect(a.announce(0, c.t), isNull);
      c.advanceS(10);
      expect(a.announce(0, c.t), isNull);
      expect(a.announce(50, c.t), isNull, reason: 'a fresh candidate; 2 s to go');
      c.advanceS(2);
      expect(a.announce(50, c.t), 50);
    });

    test('a new session re-announces the limit it starts on', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      expect(_ride(a, c, 50, 4), [50]);
      // New navigation / simulation start: the driver has not heard the current
      // limit yet, so it is announced again after the stability window.
      a.reset();
      expect(a.lastAnnounced, isNull);
      expect(_ride(a, c, 50, 4), [50],
          reason: 'a fresh session must state the limit it begins on');
    });

    test('reset keeps the note from the callout that started the session', () {
      final a = LimitChangeAnnouncer();
      final c = _Clock();
      // The turn callout said 50 as the run began, then the session state was
      // reset. The sentence was still spoken seconds ago, so repeating it now
      // would be the duplicate the user complained about — the note must
      // survive the reset.
      a.noteSpoken(50, c.t);
      a.reset();
      expect(a.announce(50, c.t), isNull, reason: 'arming the window');
      c.advanceS(2);
      expect(a.announce(50, c.t), isNull,
          reason: 'stable, but the callout just said this number out loud');
      expect(a.lastAnnounced, 50,
          reason: 'settled, so it is not announced again later either');
      c.advanceS(5);
      expect(a.announce(50, c.t), isNull);
      // Past the note's 45 s the same value may be announced again.
      c.advanceS(46);
      expect(a.announce(60, c.t), isNull, reason: 'arming the new value');
      c.advanceS(2);
      expect(a.announce(60, c.t), 60);
    });
  });

  group('manoeuvreLimitToSpeak — never a number that RISES', () {
    test('a next-street limit below the current one is spoken', () {
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 30,
          currentLimit: 50,
          namesNextStreet: true,
        ),
        30,
      );
    });

    test('an EQUAL next-street limit is spoken', () {
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 50,
          currentLimit: 50,
          namesNextStreet: true,
        ),
        50,
      );
    });

    test('a next-street limit ABOVE the current one is silence (Ấp Bắc)', () {
      // 2026-09-29: riding 50 km/h Ấp Bắc the callout ended "… rẽ trái vào Cộng
      // Hòa … Tốc độ tối đa 60 km/h" and the driver heard it as Ấp Bắc's own
      // limit. A RISING number is the change announcer's job.
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 60,
          currentLimit: 50,
          namesNextStreet: true,
        ),
        0,
      );
    });

    test('no road named → the road under the car is the useful number', () {
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 60,
          currentLimit: 50,
          namesNextStreet: false,
        ),
        50,
      );
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 0,
          currentLimit: 0,
          namesNextStreet: false,
        ),
        0,
      );
    });

    test('an unknown current limit does not block the next-street number', () {
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 60,
          currentLimit: 0,
          namesNextStreet: true,
        ),
        60,
      );
      expect(
        manoeuvreLimitToSpeak(
          nextStreetLimit: 0,
          currentLimit: 50,
          namesNextStreet: true,
        ),
        0,
      );
    });
  });
}
