/// The clock the **announcement cadences** read.
///
/// Most of the app should keep using `DateTime.now()`. But every rate limit
/// that decides *whether the driver hears something* ("don't repeat a limit
/// within 45 s", "one camera sentence per 20 s", "no rain warning twice in
/// 3 min") is a function of the drive's own time, not of the wall clock.
///
/// That distinction is what makes a fast replay honest. A recorded drive
/// replayed at 60× delivers 60 s of drive time per wall second: with
/// `DateTime.now()` the 45 s limit memory would look 60× too permissive and a
/// replayed drive would chatter with duplicates that the real drive never
/// produced — the simulation would invent bugs (or hide them). Reading the
/// **fix's own timestamp** instead keeps every cadence in drive time, so 1×
/// and 60× produce the same announcements.
///
/// A replay calls [setNavClock] with the latest fix timestamp, and
/// [resetNavClock] when it stops so a live drive is never gated by a stale
/// trip timestamp.
library;

DateTime Function() _navClock = _wallClock;

DateTime _wallClock() => DateTime.now();

/// "Now" for announcement cadences — wall clock normally, fix time in a replay.
DateTime navNow() => _navClock();

/// Test/replay hook. [clock] is expected to return the current fix's timestamp.
void setNavClock(DateTime Function() clock) {
  _navClock = clock;
}

/// Back to the real clock. Called when a replay ends so a live drive is never
/// gated by a stale trip timestamp.
void resetNavClock() {
  _navClock = _wallClock;
}

/// True while the cadences are driven by a replay rather than the wall clock.
bool get navClockIsReplay => !identical(_navClock, _wallClock);
