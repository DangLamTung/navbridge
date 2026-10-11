/// WHEN may a change in the effective speed limit be spoken?
///
/// Extracted from the navigation page so the timing contract can be tested on
/// its own (`test/services/limit_change_test.dart`). It is the whole difference
/// between one useful sentence and a stream of duplicates: a boundary the car
/// crosses at 60 km/h is past in a second, road info flickers between two
/// parallel records of the same street, and the maneuver callout may already
/// have said the number.
///
/// Three guards, all required:
///
///  1. **Stable.** The new value must hold for [stableFor] before it counts.
///     Road info can flicker (two Waze records of one street disagreeing), and
///     "Tốc độ tối đa 60" followed a second later by "… 50" is worse than
///     silence.
///  2. **Cooled down.** At most one announcement per [cooldown], so a chain of
///     short segments with different limits cannot machine-gun the driver.
///  3. **Not already said.** The turn callout ends "… Tốc độ tối đa 50 km/h.",
///     so the change announcement must not repeat the same number seconds
///     later (user, 2026-09-24: "the giới hạn tốc độ and tốc độ tối đa why have
///     2 thing" — ONE wording for the limit).
library;

/// The state machine behind the "the limit just changed" voice line.
class LimitChangeAnnouncer {
  /// How long the new limit must hold before it is announced.
  static const Duration stableFor = Duration(seconds: 2);

  /// Minimum gap between two announcements.
  static const Duration cooldown = Duration(seconds: 4);

  /// How long a value spoken by ANOTHER sentence suppresses the change callout.
  static const Duration noteValidFor = Duration(seconds: 45);

  int? _announced; // the last value announced
  int? _pending; // the value waiting to prove stable
  DateTime? _pendingSince; // when that wait started
  DateTime? _announcedAt; // when the last announcement happened
  int _notedValue = 0; // value spoken as part of another sentence
  DateTime? _notedAt;

  /// The last limit announced, or null. For tests and debug output.
  int? get lastAnnounced => _announced;

  /// Forget the announcement state for a fresh navigation / simulation session.
  ///
  /// The "already said with the turn callout" note is deliberately NOT cleared:
  /// it describes the sentence just spoken, not the session, and the callout
  /// that set it may have been the one that started this run.
  void reset() {
    _announced = null;
    _pending = null;
    _pendingSince = null;
    _announcedAt = null;
  }

  /// Remember that [kmh] was just spoken as part of another sentence (the
  /// maneuver callout, whose wording already carries the limit).
  void noteSpoken(int kmh, DateTime now) {
    _notedValue = kmh;
    _notedAt = now;
  }

  /// Was [kmh] said by another sentence within [noteValidFor]?
  bool spokenRecently(int kmh, DateTime now) {
    final at = _notedAt;
    if (at == null || _notedValue != kmh) return false;
    return now.difference(at) < noteValidFor;
  }

  /// Feed the effective limit now in force. Returns the value to ANNOUNCE, or
  /// null to stay silent — the caller speaks only when this is non-null, so
  /// every guard above lives here rather than in the widget.
  int? announce(int limit, DateTime now) {
    if (limit <= 0) return null; // no limit known → nothing to say
    if (limit == _announced) {
      // Already announced: re-arm from clean, or leaving and re-entering the
      // same limit would be swallowed by the cooldown.
      _pending = null;
      _pendingSince = null;
      return null;
    }
    if (limit != _pending) {
      _pending = limit; // a new candidate — start its stability window
      _pendingSince = now;
      return null;
    }
    final since = _pendingSince;
    if (since == null || now.difference(since) < stableFor) {
      return null; // not yet stable
    }
    final at = _announcedAt;
    if (at != null && now.difference(at) < cooldown) {
      return null; // cooldown from the last announcement
    }
    if (spokenRecently(limit, now)) {
      // Said a moment ago with the turn callout: remember it, so it does not
      // re-arm and get announced on the next fix, and stay quiet.
      _announced = limit;
      _pending = null;
      _pendingSince = null;
      return null;
    }
    _announcedAt = now;
    _announced = limit;
    _pending = null;
    _pendingSince = null;
    return limit;
  }
}

/// The speed number a manoeuvre callout should carry, and how to phrase it.
///
/// ⭐ It is no longer SILENT when the number RISES. It used to be, because a
/// rising number read as "this road is 60" while the car was still on a 50 road
/// (user, 2026-09-29: riding 50 on Ấp Bắc, "… rẽ trái vào Cộng Hòa … Tốc độ tối
/// đa 60 km/h" was heard as Ấp Bắc = 60). The cure is the WORDING, not silence:
/// a limit that is not in force yet is announced as the NEXT one — "Tốc độ
/// tiếp theo là 60 km/h" (user, 2026-10-08: "say 50 km on the next only is
/// distracting, add some line like tốc độ tiếp theo là 50 km/h").
///
/// [isNext] is true when the number belongs to the road being ENTERED and is
/// not the one in force under the car (it differs — rising or tightening) — it
/// applies from the corner onward. Phrase it "Tốc độ tiếp theo là X km/h";
/// otherwise "Tốc độ tối đa X km/h" (already in force). [kmh] 0 = say nothing.
({int kmh, bool isNext}) manoeuvreLimitToSpeak({
  required int nextStreetLimit,
  required int currentLimit,
  required bool namesNextStreet,
}) {
  // No road named → the useful number is the road under the car, already in
  // force.
  if (!namesNextStreet) {
    return (kmh: currentLimit > 0 ? currentLimit : 0, isNext: false);
  }
  if (nextStreetLimit <= 0) return (kmh: 0, isNext: false);
  // Nothing to compare against: the entered road's number, phrased normally.
  if (currentLimit <= 0) return (kmh: nextStreetLimit, isNext: false);
  // ⭐ A number that DIFFERS from the one in force is not yet in force — whether
  // it rises OR tightens — so it is said as the NEXT one either way: the driver
  // is still on the current road when they hear it.
  //
  // A tightening used to be phrased "Tốc độ tối đa 50 km/h", i.e. as if it were
  // already in force. Worse, that callout also armed the change-announcer's
  // "already said" window (45 s), so the drop was then NEVER voiced once it
  // actually took effect. Measured on the 2026-10-08 drives: every 60→50 drop
  // was SILENT (4/4) while every 50→60 rise was announced (4/4) — so the last
  // number the driver had been told stayed 60, which is exactly their report
  // "turn from 60 to 50 street … it keeps 60 km".
  return (kmh: nextStreetLimit, isNext: nextStreetLimit != currentLimit);
}

/// The sentence fragment a manoeuvre callout ends with, or '' for none.
///
/// ONE number, ONE phrase — and a number that is not in force yet says so, so it
/// can never be heard as the limit of the road under the car.
String manoeuvreLimitPhrase(({int kmh, bool isNext}) limit) {
  if (limit.kmh <= 0) return '';
  return limit.isNext
      ? ' Tốc độ tiếp theo là ${limit.kmh} km/h.'
      : ' Tốc độ tối đa ${limit.kmh} km/h.';
}
