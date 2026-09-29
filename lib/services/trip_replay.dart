import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/osrm.dart' show OsrmRoute, OsrmStep;

/// Replay a recorded drive through the real navigation algorithm.
///
/// The app already writes everything one fix consists of into its trip log
/// (`locations[]` with `timestampMs`, `latitudeE7`/`longitudeE7`, `accuracy`,
/// `velocity`, `heading`) and — the part that makes this a *measurement* rather
/// than a guess — the announcements it actually spoke (`announcements[]`, with
/// the exact text and the fix it was spoken at).
///
/// Feeding those fixes back through the page's own handler gives the same code
/// path the road took (limit chain, sign adoption, manoeuvre cadence, camera
/// chatter) without a phone, without an emulator and without spending 4 km of
/// real time per scenario: a 1 h drive replays in a minute at 60×.
///
/// Nothing here touches disk or a plugin — the caller loads the JSON (asset,
/// file or HTTP) and hands over the text, so this compiles and runs on the web
/// and in `flutter test`.
class ReplayFix {
  const ReplayFix({
    required this.at,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speedMps,
    required this.headingDeg,
    this.street = '',
    this.highway = '',
    this.divided = false,
    this.oneway,
    this.lanes,
  });

  /// The fix's own timestamp (UTC), never wall-clock: every cadence in the
  /// algorithm is measured in fix time (see `nav_clock.dart`), which is what
  /// makes a 60× replay behave exactly like the 1× drive.
  final DateTime at;
  final double lat;
  final double lng;
  final double accuracy;

  /// The ROAD the drive itself recorded at this fix, and its OSM class.
  ///
  /// ⭐ These are INPUTS, not results. On the phone the road identity comes from
  /// the on-device graph (offline) or Overpass (online) — neither exists on the
  /// web, so a browser replay had NO road name at all: the layer's own name got
  /// adopted instead, which turned the "does this segment name the road the car
  /// is on" veto into a self-reference and left the wrong street's 60 km/h on
  /// the dial (user, 2026-09-24: "still bug"). The recording carries what the
  /// phone had (`street`, `highway`, written by the trip logger while driving),
  /// so the replay can answer the same question the graph answers on the phone.
  /// `speedLimit` in the recording is deliberately NOT read: that is the old
  /// build's OUTPUT, and feeding it back would make the test circular.
  ///
  /// ⚠ [street] IS that same old output. `TripLogger.addFix` is handed
  /// `streetName: r?.name` — the name the app had PUBLISHED — so it labels the
  /// leg the drive believed it was on, which is exactly what was being asked.
  /// Measured on the 2026-09-29 08:37 drive: over Ba Vân it says "Lũy Bán Bích"
  /// for 49 fixes (OSM has Ba Vân 5.6 m away, the Waze segment 3.4 m) and over
  /// Trường Chinh it says "Trương Công Định". So it is good enough to LABEL a
  /// leg with, and not good enough to overrule the layer with — a replay must
  /// not use it as road evidence (see `_noIndependentRoadName` in nav_gps.dart).
  final String street;
  final String highway;

  /// The road FORM the graph reported while driving: [divided] = an opposite-way
  /// carriageway of the same street runs alongside; [oneway] / [lanes] feed
  /// [dividedForm]. INPUTS like [street] / [highway], NOT results.
  ///
  /// ⭐ Without them a browser replay treated EVERY road as two-way, so
  /// [vehicleCeiling] capped a Waze 60 on a đường đôi to the two-way 50 — the
  /// dial said "Waze 50" on Lũy Bán Bích where the segment pack says 60 (user,
  /// 2026-09-29: "waze now show wrong value").
  ///
  /// Same provenance rule as [street]: the old build's OUTPUT (`speedLimit` in
  /// the recording) is still deliberately NOT read.
  final bool divided;
  final bool? oneway;
  final int? lanes;

  /// m/s. Recorded when the log has it (`velocity`/`speed`), derived from the
  /// gap to the previous fix when it does not (Google-Timeline-style exports).
  final double speedMps;

  /// Degrees. Same provenance rule as [speedMps].
  final double headingDeg;

  LatLng get point => LatLng(lat, lng);

  Position toPosition() => Position(
    latitude: lat,
    longitude: lng,
    timestamp: at,
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: headingDeg,
    speed: speedMps,
    speedAccuracy: 0,
    headingAccuracy: 0,
  );
}

/// Parse a recorded trip into fixes. Accepts what the app writes and what a
/// Google Timeline export contains — the same two shapes
/// `tool/emulator_gps_replay.py` handles — so any file in `docs/trips/` works.
///
/// Returns [] for an unreadable/empty document instead of throwing: a sim that
/// silently does nothing is easier to diagnose than a crash in `main()`.
List<ReplayFix> parseReplayFixes(String jsonText) {
  Object? doc;
  try {
    doc = jsonDecode(jsonText);
  } catch (_) {
    return const [];
  }
  final List<Object?> raw;
  if (doc is List) {
    raw = doc;
  } else if (doc is Map && doc['locations'] is List) {
    raw = doc['locations'] as List<Object?>;
  } else {
    return const [];
  }

  final out = <ReplayFix>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final lat = _coord(e, 'latitudeE7', 'latitude');
    final lng = _coord(e, 'longitudeE7', 'longitude');
    final at = _time(e);
    if (lat == null || lng == null || at == null) continue;
    final acc = _num(e['accuracy']) ?? 10.0;
    out.add(
      ReplayFix(
        at: at,
        lat: lat,
        lng: lng,
        // A 0 m accuracy is a "unknown" placeholder in several exporters;
        // treat it as the honest 10 m rather than a perfect fix.
        accuracy: acc <= 0 ? 10.0 : acc,
        speedMps: (_num(e['velocity']) ?? _num(e['speed'])) ?? -1,
        headingDeg: _num(e['heading']) ?? -1,
        // The road identity the drive recorded (see ReplayFix.street).
        street: (e['street'] ?? '').toString(),
        highway: (e['highway'] ?? '').toString(),
        // The road FORM as the drive recorded it (see ReplayFix.divided).
        divided: e['divided'] == true,
        oneway: e['oneway'] is bool ? e['oneway'] as bool : null,
        lanes: _num(e['lanes'])?.toInt(),
      ),
    );
  }
  if (out.isEmpty) return const [];
  out.sort((a, b) => a.at.compareTo(b.at));
  return _fillDerived(out);
}

/// Replace the "-1 = not recorded" placeholders with values derived from the
/// movement between consecutive fixes, and clamp GPS noise: a stationary car
/// must not read 3 m/s just because the receiver wandered in its parking spot.
List<ReplayFix> _fillDerived(List<ReplayFix> fixes) {
  final out = <ReplayFix>[];
  for (var i = 0; i < fixes.length; i++) {
    final f = fixes[i];
    if (f.speedMps >= 0 && f.headingDeg >= 0) {
      out.add(f);
      continue;
    }
    var speed = f.speedMps;
    var heading = f.headingDeg;
    if (i > 0) {
      final p = fixes[i - 1];
      final dt = f.at.difference(p.at).inMilliseconds / 1000.0;
      final dist = const Distance().as(LengthUnit.Meter, p.point, f.point);
      if (dt > 0.05) {
        if (speed < 0) {
          // < 0.7 m/s over a 1 s fix is receiver jitter around a standstill.
          speed = dist < 0.7 ? 0 : dist / dt;
        }
        if (heading < 0 && dist > 1.0) {
          heading = const Distance().bearing(p.point, f.point);
        }
      }
    }
    out.add(
      ReplayFix(
        at: f.at,
        lat: f.lat,
        lng: f.lng,
        accuracy: f.accuracy,
        speedMps: speed < 0 ? 0 : speed,
        headingDeg: heading < 0 ? out.isEmpty ? 0 : out.last.headingDeg : heading,
      ),
    );
  }
  return out;
}

/// Emit [fixes] as a GPS stream at [speed]× real time (1 = the drive's own
/// pace, 0 = as fast as the consumer can take them, for tests).
///
/// [from] starts the drive at a later fix — the console's **Continue**: a run
/// that was stopped at fix N resumes at N instead of replaying the first
/// kilometre again, which is what makes "stop here, study the junction, carry
/// on" possible at all (user, 2026-09-25: "do a continue trip button which can
/// resume the trip if we stop").
///
/// The gaps come from the fixes' own timestamps, so a replayed drive keeps the
/// real 1 Hz rhythm — including the awkward ones (a 6 s tunnel dropout stays a
/// 6 s dropout) that a fixed interval would paper over.
Stream<Position> replayPositionStream(
  List<ReplayFix> fixes, {
  double speed = 1,
  int from = 0,
}) async* {
  if (fixes.isEmpty) return;
  final start = from.clamp(0, fixes.length - 1);
  var prev = fixes[start];
  yield prev.toPosition();
  for (final f in fixes.skip(start + 1)) {
    final gapMs = f.at.difference(prev.at).inMilliseconds;
    prev = f;
    if (speed > 0 && gapMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: (gapMs / speed).round()));
    }
    yield f.toPosition();
  }
}

/// Length of the replayed drive in metres — the yardstick for "this scenario
/// covers the same 3.8 km as the test drive".
double replayTripMeters(List<ReplayFix> fixes) {
  var total = 0.0;
  for (var i = 1; i < fixes.length; i++) {
    total += const Distance().as(
      LengthUnit.Meter,
      fixes[i - 1].point,
      fixes[i].point,
    );
  }
  return total;
}

/// Wall-clock span of the recorded drive (what a 1× replay costs).
Duration replayTripDuration(List<ReplayFix> fixes) =>
    fixes.length < 2
    ? Duration.zero
    : fixes.last.at.difference(fixes.first.at);

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// `latitudeE7` (integer degrees × 1e7) or a plain `latitude` double.
double? _coord(Map<Object?, Object?> m, String e7Key, String plainKey) {
  final e7 = _num(m[e7Key]);
  if (e7 != null) return e7 / 1e7;
  return _num(m[plainKey]);
}

/// `timestampMs` (ms since epoch, sometimes a string), an ISO `timestamp`, or a
/// `time` ISO string. All timestamps are normalised to UTC because the outlier
/// gate compares dt against the geolocator's (UTC) fixes.
DateTime? _time(Map<Object?, Object?> m) {
  final ms = _num(m['timestampMs']);
  if (ms != null && ms > 0) {
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }
  for (final key in const ['timestamp', 'time']) {
    final raw = m[key];
    if (raw is String) {
      final t = DateTime.tryParse(raw);
      if (t != null) return t.toUtc();
    }
  }
  return null;
}

/// Degrees of travel between two fixes — kept here so a trip without recorded
/// headings still drives the wrong-way and heading-up logic.
double bearingBetween(LatLng a, LatLng b) {
  final d = const Distance().bearing(a, b);
  return (d + 360) % 360;
}

/// Compass-difference helper used by the report tooling: 350° and 10° are 20°
/// apart, not 340°.
double angleDeltaDeg(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180 ? 360 - d : d;
}

/// Build the route the driver ACTUALLY drove, out of the recorded track.
///
/// The alternative — re-planning the journey with the router — was wrong in
/// practice, and visibly so on the web replay (2026-09-24): the router's line
/// and the driven line diverge at the first junction, the car is then
/// permanently "off route", and the app re-routes on every fix
/// (`SIM: REROUTE … fetched 2253m`), so what gets simulated is the router's
/// detour, not the drive. The track is the ground truth for the path: it is
/// where the wheels went, it follows real roads, and it needs no network — so
/// the replay is deterministic and works offline.
///
/// Manoeuvres are the places the track TURNS (bearing change over a [windowM]
/// window, merged when two land within [mergeM]). Each step is NAMED from the
/// street the recording logs over that step's own fixes — see `streetOver`
/// below. Leaving them unnamed made the engine print its "Tiến lên" placeholder
/// for a whole drive, left every callout without a street, and left
/// `routeRoadNames()` empty so the route could veto nothing.
///
/// That name is the recording's own, and the recording's `street` is the OLD
/// build's output (see [ReplayFix.street]): it LABELS a leg, it is not evidence
/// about which road the car is on.
///
/// Caveat worth knowing: a manoeuvre here is "the driver changed direction",
/// not "the map data says there is a junction", so a lane weave reads as a
/// turn. That is the honest reading of a GPS track; a planned route cannot be
/// used as a substitute for where the car went.
OsrmRoute routeFromTrack(
  List<ReplayFix> fixes, {
  double turnDeg = 25,
  double windowM = 40,
  double mergeM = 35,
}) {
  final geometry = [for (final f in fixes) f.point];
  if (geometry.length < 3) {
    return OsrmRoute(
      distance: replayTripMeters(fixes),
      duration: replayTripDuration(fixes).inSeconds.toDouble(),
      geometry: geometry,
      steps: const [],
      stopCumulative: const [],
    );
  }
  final cum = <double>[0];
  for (var i = 1; i < geometry.length; i++) {
    cum.add(cum[i - 1] + const Distance().as(
      LengthUnit.Meter,
      geometry[i - 1],
      geometry[i],
    ));
  }
  final total = cum.last;

  /// Bearing of the track over [windowM] ending at [i].
  double bearingEndingAt(int i) {
    var j = i;
    while (j > 0 && cum[i] - cum[j] < windowM) {
      j--;
    }
    if (j == i) return const Distance().bearing(geometry[i - 1], geometry[i]);
    return const Distance().bearing(geometry[j], geometry[i]);
  }

  /// Bearing of the track over [windowM] starting at [i].
  double bearingStartingAt(int i) {
    var j = i;
    while (j < geometry.length - 1 && cum[j] - cum[i] < windowM) {
      j++;
    }
    if (j == i) return const Distance().bearing(geometry[i], geometry[i + 1]);
    return const Distance().bearing(geometry[i], geometry[j]);
  }

  final turns = <int>[];
  for (var i = 1; i < geometry.length - 1; i++) {
    if (cum[i] < 15 || total - cum[i] < 15) continue; // not at the very ends
    final delta = _deltaDeg(bearingStartingAt(i), bearingEndingAt(i));
    if (delta.abs() < turnDeg) continue;
    if (turns.isNotEmpty && cum[i] - cum[turns.last] < mergeM) {
      // Two hits on the same junction (a curve read twice) — keep the sharper.
      final prev = turns.last;
      if (delta.abs() > _deltaDeg(bearingStartingAt(prev), bearingEndingAt(prev)).abs()) {
        turns[turns.length - 1] = i;
      }
      continue;
    }
    turns.add(i);
  }

  // Steps must TILE the route: each one starts where the previous ends and the
  // distances sum to the route's own total. The engine positions the banner
  // from them (its `_stepCum` is a running sum of step distances, and the
  // "arrive" step is only reached once that sum reaches the total).
  //
  // ⭐ Each step is NAMED with the street the drive recorded over that leg.
  // Leaving `name: ''` made the engine fall back to its "Tiến lên" placeholder
  // (nav_engine.dart: `cur.name.isNotEmpty ? cur.name : kContinuePlaceholder`),
  // so a replayed drive showed "Tiến lên" in the banner for the whole route and
  // every callout came out as "rẽ phải." with no street — and `routeRoadNames()`
  // had nothing to veto with, so the road-name resolution could not be tested in
  // the simulator at all (user, 2026-09-29: "the navigation on map only show tiến
  // lên, this is wrong too").
  //
  // The name is the MAJORITY recorded street over the step's own fixes — the
  // phone's own name for that leg, which is exactly what the replay is replaying.
  String streetOver(int from, int to) {
    final counts = <String, int>{};
    final a = from.clamp(0, fixes.length - 1);
    final b = to.clamp(a + 1, fixes.length);
    for (var i = a; i < b; i++) {
      final s = fixes[i].street.trim();
      if (s.isEmpty) continue;
      counts[s] = (counts[s] ?? 0) + 1;
    }
    if (counts.isEmpty) return '';
    return counts.entries
        .reduce((x, y) => y.value > x.value ? y : x)
        .key;
  }

  final steps = <OsrmStep>[
    OsrmStep(
      name: streetOver(0, turns.isEmpty ? geometry.length : turns.first),
      distance: turns.isEmpty ? total : cum[turns.first],
      duration: turns.isEmpty ? total : cum[turns.first],
      type: 'depart',
      modifier: null,
      maneuver: geometry.first,
    ),
  ];
  for (var k = 0; k < turns.length; k++) {
    final t = turns[k];
    final next = k + 1 < turns.length ? turns[k + 1] : geometry.length;
    final end = k + 1 < turns.length ? cum[turns[k + 1]] : total;
    final delta = _deltaDeg(bearingStartingAt(t), bearingEndingAt(t));
    steps.add(
      OsrmStep(
        name: streetOver(t, next),
        distance: end - cum[t],
        duration: end - cum[t],
        type: 'turn',
        modifier: _modifierFor(delta),
        maneuver: geometry[t],
      ),
    );
  }
  steps.add(
    OsrmStep(
      name: '',
      distance: 0,
      duration: 0,
      type: 'arrive',
      modifier: null,
      maneuver: geometry.last,
    ),
  );

  return OsrmRoute(
    distance: total,
    duration: replayTripDuration(fixes).inSeconds.toDouble(),
    geometry: geometry,
    steps: steps,
    stopCumulative: [total],
  );
}

/// Signed turn angle in degrees: positive = right, negative = left, normalised
/// to (-180, 180].
double _deltaDeg(double to, double from) {
  var d = (to - from) % 360.0;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// OSRM's modifier vocabulary, so the existing voice phrases read the same as
/// they do for a planned route.
String _modifierFor(double delta) {
  final a = delta.abs();
  final side = delta > 0 ? 'right' : 'left';
  if (a >= 120) return 'sharp $side';
  if (a >= 45) return side;
  return 'slight $side';
}

/// Where a replay gets its trip, and how fast to run it.
///
/// Two ways in, because they answer different questions:
///
///   * `--dart-define=REPLAY_TRIP=...` / `REPLAY_SPEED=20` — a phone or
///     emulator build that replays a fixed drive. Compile-time, so the same
///     APK always replays the same scenario.
///   * the browser URL, `?trip=/sim_trip.json&speed=20` — the scenario is
///     chosen per page load, so a new drive or a new speed costs a reload
///     instead of a 47 s rebuild. Drop any recorded trip into the served
///     directory as `sim_trip.json` and it drives.
///
/// [injectedJson] is the test hook: a trip read from disk (or built inline) is
/// handed straight to the page, with no asset or network involved.
class TripReplay {
  const TripReplay._();

  static const String _defineTrip = String.fromEnvironment('REPLAY_TRIP');
  static const String _defineSpeed = String.fromEnvironment('REPLAY_SPEED');

  /// Raw trip JSON for tests. Setting it arms the replay.
  @visibleForTesting
  static String? injectedJson;

  /// Raw trip JSON handed in at runtime — the console's file picker reads a
  /// JSON straight off the user's disk (a drive that was never staged into the
  /// served directory, or a fixture someone is testing). Kept separate from
  /// [injectedJson] (a test hook) so the two can never be confused.
  static String? inlineJson;
  static String inlineLabel = '';

  /// Sentinel ref for a trip whose bytes are already in memory.
  static const String inlineRef = 'inline:';

  static String? get _urlTrip {
    if (!kIsWeb) return null;
    final v = Uri.base.queryParameters['trip'];
    return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
  }

  static double? get _urlSpeed {
    if (!kIsWeb) return null;
    return double.tryParse(Uri.base.queryParameters['speed'] ?? '');
  }

  /// Asset path, file path or URL of the trip to replay — null on a normal run
  /// (no receiver-driven replay armed).
  static String? get source {
    if (injectedJson != null) return 'injected';
    if (_runtimeRef != null) return _runtimeRef;
    final url = _urlTrip;
    if (url != null) return url;
    return _defineTrip.isEmpty ? null : _defineTrip;
  }

  static bool get armed => source != null;

  // ---------------------------------------------------------------------
  // Runtime control — what the replay console presses.
  //
  // The URL/define paths above arm a replay at BOOT (good for scripted runs:
  // one URL, one scenario). A debug console needs the opposite: pick a trip,
  // press Start, watch; press Stop, pick another, press Start again — all
  // without a page reload. So the console sets a runtime ref here and bumps
  // [revision]; the page listens and (re)starts or stops the run.
  // ---------------------------------------------------------------------

  static String? _runtimeRef;

  /// Auto-start at boot (URL query / dart-define) rather than from the console.
  static bool get armedAtBoot => _urlTrip != null || _defineTrip.isNotEmpty;

  /// Bumped when the console asks for a start (odd) or a stop (even is not
  /// required — [running] says which).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Set by the page: true while fixes are actually being fed.
  static bool running = false;

  static bool _stopWanted = false;

  /// True when the last console press was Stop.
  static bool get stopWanted => _stopWanted;

  /// Ask for a run of [ref] at [speed]. The page picks it up via [revision].
  ///
  /// [from] = the fix to start at (see [resumeFor]): null continues from where
  /// the last run of this trip stopped, 0 starts over.
  static void start(String ref, {required double speed, int? from}) {
    _runtimeRef = ref;
    speedOverride = speed;
    pendingFrom = from ?? resumeFor(ref);
    _stopWanted = false;
    revision.value++;
  }

  /// Fix the run now being started will begin at (set by [start]).
  static int pendingFrom = 0;

  /// `?from=N` — start the replayed drive at fix N (absent/0 = the whole drive).
  ///
  /// The console's "Tiếp tục" button is the normal way into this; the URL form
  /// exists so a scripted run (or a screenshot) can land on ONE junction without
  /// driving the first kilometre — the same thing the button does, minus the
  /// clicking.
  static int get urlFrom {
    final v = int.tryParse(Uri.base.queryParameters['from'] ?? '');
    return (v == null || v < 0) ? 0 : v;
  }

  /// The fix the run about to start should begin at: an explicit request
  /// ([pendingFrom], set by [start]) beats `?from=`, which is the whole point
  /// of the button. 0 = start at the beginning.
  static int get startFrom => pendingFrom > 0 ? pendingFrom : urlFrom;

  /// Where the last run of a trip STOPPED, per trip ref, so the console can
  /// offer "Tiếp tục" (`Continue`) instead of only "Bắt đầu" (start over).
  ///
  /// Kept next to the trip rather than in the page because the console and the
  /// page must agree on which trip the point belongs to — a resume that crossed
  /// trips would silently skip a different drive's first N fixes.
  static String _stoppedRef = '';
  static int _stoppedAt = 0;

  /// Remember that a run of [ref] stopped after [fix] fixes.
  static void noteStopped(String ref, int fix) {
    if (ref.isEmpty || fix <= 0) return;
    _stoppedRef = ref;
    _stoppedAt = fix;
    revision; // (no notify: the console polls this through simTick)
  }

  /// The fix a Continue should resume [ref] at (0 = nothing to continue).
  static int resumeFor(String ref) =>
      ref.isNotEmpty && ref == _stoppedRef ? _stoppedAt : 0;

  /// Forget the resume point — a finished run, or "start over".
  static void clearResume([String? ref]) {
    if (ref == null || ref == _stoppedRef) {
      _stoppedRef = '';
      _stoppedAt = 0;
    }
  }

  /// Drive a trip whose JSON was handed in directly (file picker).
  static void startInline(
    String json, {
    required String label,
    required double speed,
    int? from,
  }) {
    inlineJson = json;
    inlineLabel = label.isEmpty ? 'inline.json' : label;
    start(inlineRef, speed: speed, from: from);
  }

  /// Ask the page to stop the current run.
  static void stop() {
    _stopWanted = true;
    revision.value++;
  }

  /// Runtime speed, set by the console; falls back to the URL/define.
  static double? speedOverride;

  /// 1 = the drive's own pace; 0 = as fast as the pipeline can consume fixes
  /// (tests, CI sweeps); 20 = a 1 h drive in 3 minutes.
  static double get speed {
    final s = speedOverride ?? _urlSpeed ?? double.tryParse(_defineSpeed);
    if (s == null || !s.isFinite || s < 0) return 1;
    return s;
  }

  /// Load + parse the armed trip. Accepts a full `http(s)://` URL, a
  /// root-relative path on the web (`/sim_trip.json`, served next to the app —
  /// no rebuild per scenario), otherwise an asset key (what the APK and the web
  /// bundle both carry).
  static Future<List<ReplayFix>> load([String? ref]) async {
    final r = ref ?? source;
    if (r == null) return const [];
    if (r == 'injected') return parseReplayFixes(injectedJson ?? '');
    if (r == inlineRef) {
      final text = inlineJson;
      return text == null ? const [] : parseReplayFixes(text);
    }
    try {
      final text = _isUrl(r)
          ? (await http.get(Uri.base.resolve(r))).body
          : await rootBundle.loadString(r);
      final fixes = parseReplayFixes(text);
      _loaded = fixes; // so the running replay can answer `streetAt` — see below
      return fixes;
    } catch (e) {
      debugPrint('REPLAY: cannot load "$r": $e');
      return const [];
    }
  }

  /// The fixes of the trip currently loaded, in fix time.
  static List<ReplayFix> _loaded = const [];

  /// The ROAD the drive itself recorded for a fix at [at] ('' when the log has
  /// none / nothing is loaded).
  ///
  /// This is the replay's stand-in for the on-device graph: on the phone the
  /// road identity comes from the graph (offline) or Overpass (online), and on
  /// the web neither exists — so without this the replay never knew which road
  /// the car was on, and the segment-name veto had no reference to compare
  /// against (2026-09-24: the browser kept showing a neighbour street's 60 km/h
  /// while the code was already correct).
  ///
  /// Nearest fix within 3 s, not an exact match: the stream hands out `Position`s
  /// whose timestamps are the fix's own, so an exact key is available — but a
  /// tolerance keeps it working if the cadence is rescaled.
  static ReplayFix? streetAt(DateTime at) {
    if (_loaded.isEmpty) return null;
    var lo = 0, hi = _loaded.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_loaded[mid].at.isBefore(at)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    ReplayFix? best;
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= _loaded.length) continue;
      final f = _loaded[i];
      if (best == null ||
          (f.at.difference(at).abs() < best.at.difference(at).abs())) {
        best = f;
      }
    }
    if (best == null || best.at.difference(at).abs() > const Duration(seconds: 3)) {
      return null;
    }
    return best;
  }

  /// A URL is anything absolute, or — on the web — a root-relative path, which
  /// is how a trip dropped into the served directory is addressed. An asset key
  /// (`assets/trips/x.json`) is not a URL and goes through [rootBundle].
  static bool _isUrl(String r) {
    if (r.startsWith('http://') || r.startsWith('https://')) return true;
    return kIsWeb && r.startsWith('/');
  }

  /// Trips the console can offer. Web: `/trips/index.json`, written next to the
  /// web build by `tool/sim_trips.py`. Phone/desktop: `assets/trips/index.json`,
  /// bundled by `tool/sim_trips.py --asset` (refs are asset keys). [] when
  /// neither exists — the console then falls back to its path/URL box.
  static Future<List<({String name, String ref, double km})>> servedTrips() async {
    if (kIsWeb) {
      final web = await _tripsFromJson(() async {
        final res = await http.get(Uri.base.resolve('/trips/index.json'));
        return res.statusCode == 200 ? res.body : null;
      });
      if (web.isNotEmpty) return web;
    }
    return _tripsFromJson(() async {
      try {
        return await rootBundle.loadString('assets/trips/index.json');
      } catch (_) {
        return null; // no bundled catalogue (see servedTrips)
      }
    });
  }

  /// Parse a `{name, ref, km}` catalogue; a malformed one yields [] rather than
  /// breaking the console.
  static Future<List<({String name, String ref, double km})>> _tripsFromJson(
    Future<String?> Function() read,
  ) async {
    try {
      final body = await read();
      if (body == null) return const [];
      final doc = jsonDecode(body);
      if (doc is! List) return const [];
      final out = <({String name, String ref, double km})>[];
      for (final e in doc) {
        if (e is! Map) continue;
        final name = e['name']?.toString() ?? '';
        final ref = e['ref']?.toString() ?? '';
        if (name.isEmpty || ref.isEmpty) continue;
        final km = (e['km'] is num) ? (e['km'] as num).toDouble() : 0.0;
        out.add((name: name, ref: ref, km: km));
      }
      return out;
    } catch (e) {
      debugPrint('REPLAY: no trip catalogue: $e');
      return const [];
    }
  }
}
