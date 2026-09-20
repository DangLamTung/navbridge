part of '../navigation_page.dart';

/// Per-GPS-fix throttle shared by the route checks (camera / sign / …): the
/// scan runs at most once per second, even though a GPS fix arrives more
/// often.
class _PerSecondGate {
  DateTime? _last;

  /// Opens the gate (allowing this check to run) and records the time, or
  /// returns false if a check already ran within the last second.
  bool tryOpen() {
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < const Duration(seconds: 1)) {
      return false;
    }
    _last = now;
    return true;
  }

  /// Re-arm for a fresh session (e.g. a new navigation / simulation start).
  void reset() => _last = null;
}

/// Speaks each route item at most twice — once in the "far" zone and once in
/// the "near" zone — by remembering announced signatures for the session.
///
/// A single `_last` entry is NOT enough: with several cameras close together
/// (or GPS jitter flipping which camera is nearest), the "nearest ahead"
/// camera can alternate between A and B, and a `_last`-only dedup would
/// re-announce each time it flips back. This remembers a bounded SET of
/// signatures so each physical camera (per zone) is spoken at most once.
class _ZoneDedupe {
  final Set<String> _seen = {};

  /// True if [sig] has already been announced (skip it); false if this is a
  /// new announcement (the caller should speak it).
  bool seen(String sig) => !_seen.add(sig);

  /// Forget every announcement (e.g. a new navigation session).
  void reset() => _seen.clear();
}
