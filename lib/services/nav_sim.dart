import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

/// The replay console is WEB-ONLY (user rule): a phone build is a navigation
/// device and must not show simulation UI. No dart-define may change this.
bool get simConsoleEnabled => kIsWeb;

/// One announcement a navigation run produced, with enough context to answer
/// "why did it say that, there?" without watching a screen.
class SimAnnouncement {
  const SimAnnouncement({
    required this.at,
    required this.text,
    required this.kind,
    this.position,
    this.metersToManeuver,
    this.limitKmh,
    this.limitSrc,
    this.roadContext,
    this.vehicle,
  });

  /// The FIX time, not the wall clock — in a 60× replay a 2-second gap here is
  /// 2 seconds of the drive (see `nav_clock.dart`).
  final DateTime at;
  final String text;

  /// `voice` (manoeuvre), `camera`, `limit`, `overspeed`, `gps`, `rain`, …
  /// The same labels the trip log writes, so a replayed run and a recorded
  /// drive can be diffed directly.
  final String kind;
  final LatLng? position;

  /// Distance to the upcoming manoeuvre at the moment of speaking — the number
  /// that answers "it said the turn NOW, was that 400 m out or 40 m out?".
  final int? metersToManeuver;

  /// The limit that was in force when the sentence was spoken, where it came
  /// from ('sign' | 'road'), and the road/class/form behind it. Without these a
  /// "Tốc độ tối đa 60 km/h" is unarguable — with them, the claim can be checked
  /// against the street it was said on (the point of the replay harness).
  final int? limitKmh;
  final String? limitSrc;
  final String? roadContext;
  final String? vehicle;

  @override
  String toString() {
    final clock = at.toIso8601String().substring(11, 19);
    final pos = position == null
        ? ''
        : ' @${position!.latitude.toStringAsFixed(5)},'
              '${position!.longitude.toStringAsFixed(5)}';
    final m = metersToManeuver == null ? '' : ' ${metersToManeuver!}m';
    final lim = limitKmh == null
        ? ''
        : ' [limit $limitKmh${limitSrc == null ? '' : ' via $limitSrc'}'
              '${vehicle == null ? '' : ' $vehicle'}]';
    final ctx = roadContext == null ? '' : ' <$roadContext>';
    return '$clock [$kind]$pos$m$lim$ctx $text';
  }
}

/// Where a replayed run sends its announcements. When null (a normal drive) the
/// app speaks; when set, the announcement is recorded instead.
///
/// This exists because the voice guards (`if (!_voice.ready) return;`) are also
/// decision gates: without a way to say "the driver is listening", a headless
/// replay would silently skip the code under test. Capturing at
/// `_logAnnouncement` — the one funnel every spoken sentence already passes
/// through, which is how the camera chatter was counted from real trip files —
/// keeps the measurement on the real path.
typedef SimAnnouncementSink = void Function(SimAnnouncement a);

SimAnnouncementSink? simAnnouncementSink;

/// True while a run is being recorded rather than driven — the voice guards
/// treat the driver as listening, and the phrases are captured, not spoken.
bool get simCapturing => simAnnouncementSink != null;

/// Hand an announcement to the sink, if one is installed.
void simAnnounce(
  String text, {
  required String kind,
  required DateTime at,
  LatLng? position,
  int? metersToManeuver,
  int? limitKmh,
  String? limitSrc,
  String? roadContext,
  String? vehicle,
}) {
  final sink = simAnnouncementSink;
  if (sink == null || text.isEmpty) return;
  final a = SimAnnouncement(
    at: at,
    text: text,
    kind: kind,
    position: position,
    metersToManeuver: metersToManeuver,
    limitKmh: limitKmh,
    limitSrc: limitSrc,
    roadContext: roadContext,
    vehicle: vehicle,
  );
  _logForConsole(a);
  sink(a);
}

/// A run's worth of captured announcements, in order.
class SimRecorder {  final List<SimAnnouncement> announcements = [];

  /// Install as the sink; call [detach] when the run ends so a live drive is
  /// never recorded by accident.
  void attach() {
    simAnnouncementSink = (a) => announcements.add(a);
  }

  void detach() {
    simAnnouncementSink = null;
  }

  /// Announcements of one kind, in order.
  List<SimAnnouncement> ofKind(String kind) =>
      announcements.where((a) => a.kind == kind).toList();

  /// Repeat groups of the same text within [within] of drive time — the
  /// duplicate-chatter metric (a repeated limit, the same camera sentence
  /// twice) that has to stay at zero.
  List<List<SimAnnouncement>> repeatsWithin(Duration within) {
    final out = <List<SimAnnouncement>>[];
    for (var i = 0; i < announcements.length; i++) {
      final a = announcements[i];
      final group = <SimAnnouncement>[a];
      for (var j = i + 1; j < announcements.length; j++) {
        final b = announcements[j];
        if (b.text != a.text) continue;
        if (b.at.difference(a.at) > within) break;
        group.add(b);
        i = j;
      }
      if (group.length > 1) out.add(group);
    }
    return out;
  }

  /// One line per announcement, for a console report / CI log.
  String report({String? title}) {
    final b = StringBuffer();
    if (title != null) b.writeln('== $title (${announcements.length}) ==');
    for (final a in announcements) {
      b.writeln(a);
    }
    final repeats = repeatsWithin(const Duration(seconds: 45));
    b.writeln('duplicate texts within 45 s of drive time: ${repeats.length}');
    for (final g in repeats) {
      b.writeln('  ${g.length}× "${g.first.text}"');
    }
    return b.toString();
  }

  /// Await the first announcement matching [test] (or null on timeout) — lets a
  /// behaviour test wait for the thing it is about to assert on.
  Future<SimAnnouncement?> waitFor(
    bool Function(SimAnnouncement a) test, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final done = Completer<SimAnnouncement?>();
    void check() {
      if (done.isCompleted) return;
      for (final a in announcements) {
        if (test(a)) {
          done.complete(a);
          return;
        }
      }
    }

    check();
    if (done.isCompleted) return done.future;
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      check();
      if (done.isCompleted) return;
    });
    return done.future.whenComplete(timer.cancel).timeout(
      timeout,
      onTimeout: () => null,
    );
  }
}

// ---------------------------------------------------------------------------
// Live state of the current simulated run.
//
// The replay console (`nav_sim_panel.dart`) is a debug UI: it needs to see what
// the run is doing WHILE it happens — progress, how far the road lookup is
// behind, and every sentence in the order it was said. That state lives here
// rather than in the page so the console can read it without reaching into
// private page fields, and so the same numbers appear in the console, the
// `ANNOUNCE:` console lines and the end-of-run report.
// ---------------------------------------------------------------------------

/// What the run is doing right now.
enum SimRunState { idle, loading, running, done, stopped, failed }

/// Announcements of the CURRENT run (capped — a long drive can say hundreds).
final List<SimAnnouncement> simLog = <SimAnnouncement>[];
const int _simLogCap = 400;

/// Bumped by everything the console draws, so one listener can refresh the
/// panel without polling.
final ValueNotifier<int> simTick = ValueNotifier<int>(0);

/// Which trip is loaded and how fast it is running ('' when none).
String simTripLabel = '';
String simTripRef = '';
double simSpeed = 1;

/// Fixes fed into the pipeline, and how many of them had no road resolved yet —
/// the "is the lookup keeping up?" metric. A replay that outruns the per-fix
/// lookups UNDER-reports announcements, so this is the number that says whether
/// a result can be trusted.
int simFixesFed = 0;
int simFixesNoRoad = 0;

/// Total fixes in the loaded trip (0 when none).
int simFixesTotal = 0;

/// Drive length / duration of the loaded trip.
double simTripMeters = 0;
Duration simTripDuration = Duration.zero;

/// Wall-clock start of the run (for "ran in Xs" in the console).
DateTime? simStartedAt;

SimRunState _simState = SimRunState.idle;
SimRunState get simState => _simState;

/// True while fixes are being fed.
bool get simRunning => _simState == SimRunState.running;

void _setState(SimRunState s) {
  _simState = s;
  simTick.value++;
}

/// Reset the per-run numbers and log (called when a run starts).
void simBeginRun({
  required String label,
  required String ref,
  required double speed,
  required int fixes,
  required double meters,
  required Duration duration,
  /// Fix the run STARTS at: >0 when resuming a stopped run, so the counters and
  /// the "N/M fixes fed" line describe the drive, not the run.
  int fromFix = 0,
}) {
  simLog.clear();
  simTripLabel = label;
  simTripRef = ref;
  simSpeed = speed;
  simFixesFed = fromFix;
  simFixesNoRoad = 0;
  simFixesTotal = fixes;
  simTripMeters = meters;
  simTripDuration = duration;
  simStartedAt = DateTime.now();
  _setState(SimRunState.running);
}

/// Record one fed fix (and whether its road was resolved).
void simNoteFix({required bool roadKnown}) {
  simFixesFed++;
  if (!roadKnown) simFixesNoRoad++;
  // The panel redraws per fix; at a fast replay rate that is more often than a
  // 60 Hz display can use, so only the counters are published here and the
  // announcement log drives its own updates.
  if (simFixesFed % 10 == 0) simTick.value++;
}

/// Append an announcement to the live log (called from [simAnnounce]).
void _logForConsole(SimAnnouncement a) {
  simLog.add(a);
  if (simLog.length > _simLogCap) simLog.removeAt(0);
  simTick.value++;
}

void simEndRun(SimRunState state) => _setState(state);

// ---------------------------------------------------------------------------
// Debug LAYERS.
//
// The point of a simulator is to see WHY a decision was made, and for limits,
// cameras and signs that means seeing the data itself under the car. These
// toggles draw the real layers on the map:
//
//   * cameras  — every camera record in view, coloured by what it enforces;
//   * signs    — every road sign in view, with its posted value;
//   * segments — the Waze posted-limit SEGMENTS, coloured by limit, with the
//                record that actually answered the last lookup highlighted.
//
// "Don't cheap out on computing" is taken literally here: the layers are loaded
// in full and filtered only by the map view being drawn. What is NOT done is
// rendering 70k markers at once, which costs frames for nothing a driver can
// see — the view filter is a rendering decision, not a data one.
// ---------------------------------------------------------------------------

bool simShowCameras = false;
bool simShowSigns = false;
bool simShowSegments = false;

/// Full data sets, loaded on first toggle. Kept for the session: reloading a
/// 22 MB asset every time a checkbox is ticked would be the cheap-out.
List<OfflineCamera>? simAllCameras;
List<RoadSign>? simAllSigns;
List<WazeSegment>? simSegments;

/// What the debug layers currently hold, for the console's counters.
int simLayerCameras = 0;
int simLayerSigns = 0;
int simLayerSegments = 0;

/// Toggle a debug layer on/off and report the new state.
void simSetLayer(String layer, bool on) {
  switch (layer) {
    case 'cameras':
      simShowCameras = on;
    case 'signs':
      simShowSigns = on;
    case 'segments':
      simShowSegments = on;
  }
  simTick.value++;
}

bool simLayerOn(String layer) => switch (layer) {
  'cameras' => simShowCameras,
  'signs' => simShowSigns,
  'segments' => simShowSegments,
  _ => false,
};

// ---------------------------------------------------------------------------
// Route / Waypoint Editor (Web Debug)
// ---------------------------------------------------------------------------

bool simEditorMode = false;
final List<LatLng> simEditorWaypoints = [];

void simToggleEditor([bool? enable]) {
  simEditorMode = enable ?? !simEditorMode;
  simTick.value++;
}

void simAddEditorWaypoint(LatLng point) {
  simEditorWaypoints.add(point);
  simTick.value++;
}

void simRemoveEditorWaypoint(int index) {
  if (index >= 0 && index < simEditorWaypoints.length) {
    simEditorWaypoints.removeAt(index);
    simTick.value++;
  }
}

void simClearEditorWaypoints() {
  simEditorWaypoints.clear();
  simTick.value++;
}



