/// Trip logger — records position fixes while navigating and exports them in
/// the Google Takeout "Location History" format (`Records.json`).
///
/// The exported file is compatible with Google Takeout's classic `Records.json`
/// layout so it can be imported/visualised with existing timeline tools:
///
/// ```json
/// { "locations": [
///   { "timestampMs": "1754000000000",
///     "latitudeE7": 1082310000, "longitudeE7": 1066297000,
///     "accuracy": 5, "source": "GPS",
///     "activity": [ { "timestampMs": "…",
///       "activity": [ { "type": "IN_VEHICLE", "confidence": 100 } } ] } ] }
/// ] }
/// ```
///
/// In addition to the raw fixes, the logger detects "places" — where the
/// vehicle was stationary long enough to count as a stop (Google-Timeline
/// style) — and records them so the trips screen can show the places you
/// visited on a given date.
///
/// CONTINUOUS WRITE: the Takeout document can only be written whole, and
/// [saveTrip] runs when navigation STOPS — so a drive killed mid-way (force
/// stop, OOM, crash, battery pull) used to be lost completely. Every fix /
/// announcement / place is therefore ALSO appended to a `<trip>.part` spool as
/// one JSON line and flushed immediately ([TripSpool]); [recoverSpooledTrips]
/// rebuilds a normal trip from it at the next launch, up to the final second.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_poi.dart';
import 'osrm.dart' show distanceMeters;

/// One recorded fix (mirrors a Google Takeout `locations` entry).
class TripFix {
  final DateTime time;
  final double lat;
  final double lng;
  final double accuracyM; // meters
  final double speedMps; // m/s (0 when unknown)
  final double? heading; // degrees, 0 = N (null when unknown)
  final String source; // 'GPS' | 'SIM'

  /// Current road the car is on (debug: compare against announcements).
  final String? streetName;
  final String? highway; // OSM/GraphHopper class (primary, service, …)

  /// The ROAD's own tagged / statutory value (what the road data says).
  final int? speedLimit;

  /// The EFFECTIVE limit actually used by the chip / overspeed alert
  /// (sign-aware, vehicle-capped). Logged alongside [speedLimit] + [limitSource]
  /// so a spoken-limit-vs-road mismatch can be proven from a recorded trip.
  final int? limitEffective;

  /// Which layer produced [limitEffective]: 'sign' | 'road'.
  final String? limitSource;

  /// The badge layer behind the ROAD's value — the chain the limit came from:
  /// 'segment' (Waze posted limit under the car) | 'waze' | 'vietmap' (VN
  /// posted-limit points) | 'osm' (the way's `maxspeed` tag) | 'city' (built-up
  /// rule) | 'class' (statutory class default). See [RoadInfo.src].
  final String? limitLayer;

  /// Vehicle class the limit was computed for: 'car' | 'motorbike' | 'truck'.
  /// The statutory tables differ per class (mô tô primary/tertiary = 60 where
  /// the car law says 80/50), so a logged limit cannot be audited without it.
  final String? vehicle;

  /// Inputs of the statutory / built-up decision, logged so every recorded
  /// value can be re-derived offline: OSM class ([highway]) + [vehicle] +
  /// these three + [urban].
  final bool? oneway;
  final int? lanes;
  final bool? divided;

  /// True when the built-up ("khu đông dân cư") rule chose the value — the
  /// POI-density test said town and nothing was posted, so the road-FORM limit
  /// applied (50 hai chiều / 60 đường đôi) instead of the rural class default.
  final bool? urban;

  TripFix({
    required this.time,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.speedMps,
    this.heading,
    required this.source,
    this.streetName,
    this.highway,
    this.speedLimit,
    this.limitEffective,
    this.limitSource,
    this.limitLayer,
    this.vehicle,
    this.oneway,
    this.lanes,
    this.divided,
    this.urban,
  });

  Map<String, dynamic> toTakeout() {
    final ms = time.millisecondsSinceEpoch.toString();
    return {
      'timestamp': time.toUtc().toIso8601String(),
      'timestampMs': ms,
      'latitudeE7': (lat * 1e7).round(),
      'longitudeE7': (lng * 1e7).round(),
      'accuracy': accuracyM.round(),
      'velocity': speedMps.round(),
      'source': source,
      'heading': heading?.round(), // debug: the displayed travel heading
      if (streetName != null) 'street': streetName,
      if (highway != null) 'highway': highway,
      if (speedLimit != null) 'speedLimit': speedLimit,
      if (limitEffective != null) 'limitEffective': limitEffective,
      if (limitSource != null) 'limitSource': limitSource,
      // Which layer / vehicle class / road tags decided that number.
      if (limitLayer != null) 'limitLayer': limitLayer,
      if (vehicle != null) 'vehicle': vehicle,
      if (oneway != null) 'oneway': oneway,
      if (lanes != null) 'lanes': lanes,
      if (divided != null) 'divided': divided,
      if (urban != null) 'urban': urban,
      'activity': [
        {
          'timestampMs': ms,
          'activity': [
            {'type': speedMps > 2 ? 'IN_VEHICLE' : 'STILL', 'confidence': 100},
          ],
        },
      ],
    };
  }
}

/// A place the vehicle stopped at (Google-Timeline style). Detected when the
/// track stays within a small radius for [TripLogger._stopMinStillSeconds].
class TripPlace {
  final DateTime enteredAt;
  final DateTime leftAt;
  final double lat;
  final double lng;

  /// Best-effort place/POI name (null until resolved by [TripLogger]).
  String? name;

  /// Total time spent here.
  Duration get duration => leftAt.difference(enteredAt);

  TripPlace({
    required this.enteredAt,
    required this.leftAt,
    required this.lat,
    required this.lng,
    this.name,
  });

  Map<String, dynamic> toJson() => {
    'enteredAt': enteredAt.toIso8601String(),
    'leftAt': leftAt.toIso8601String(),
    'lat': lat,
    'lng': lng,
    if (name != null) 'name': name,
  };

  factory TripPlace.fromJson(Map<String, dynamic> j) => TripPlace(
    enteredAt:
        DateTime.tryParse((j['enteredAt'] ?? '') as String) ?? DateTime.now(),
    leftAt: DateTime.tryParse((j['leftAt'] ?? '') as String) ?? DateTime.now(),
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
    name: j['name'] as String?,
  );
}

/// One voice announcement made during the drive (debug: correlate with the
/// fixes and the road the car was on when it fired).
class TripAnnouncement {
  final DateTime time;
  final double lat;
  final double lng;
  final String
  kind; // 'maneuver' | 'overspeed' | 'limit' | 'gps' | 'camera' | 'sign' | 'rain'
  final String text;

  TripAnnouncement({
    required this.time,
    required this.lat,
    required this.lng,
    required this.kind,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'timestampMs': time.millisecondsSinceEpoch.toString(),
    'lat': lat,
    'lng': lng,
    'kind': kind,
    'text': text,
  };
}

/// A single recording session. Sample like Google does: at most one fix every
/// 5 s unless the position moved more than 20 m.
class TripLogger {
  final String name; // trip label (usually the destination)
  final DateTime startedAt;
  final List<TripFix> fixes = [];

  /// Detected stops ("places"), in the order they were entered.
  final List<TripPlace> places = [];

  /// Voice announcements made during the drive, in order, each tagged with the
  /// position + time so they can be compared against the fixes / street data.
  final List<TripAnnouncement> announcements = [];

  TripLogger({required this.name, DateTime? startedAt, this.spoolDir})
    : startedAt = startedAt ?? DateTime.now() {
    _spool = TripSpool(fileName: defaultFileName, dir: spoolDir);
  }

  /// Where the continuous spool is written. Tests inject a temp dir; the app
  /// passes null and the spool uses [tripsDirectory].
  final Directory? spoolDir;

  /// The continuous writer — see [TripSpool].
  late final TripSpool _spool;

  // Record at ~1 Hz (1 s / 5 m): standard steady rate — enough that slow
  // heading flips still show in the log without bloating the file.
  static const Duration _minInterval = Duration(seconds: 1);
  static const double _minDistance = 5.0;

  // Place detection: the car must be nearly stationary for at least this
  // long inside a ~120 m radius to count as a visited place. The trip's very
  // first fix (origin) is excluded so a short pause right after navigation
  // starts doesn't fake a place.
  static const Duration _stopMinStillSeconds = Duration(seconds: 90);
  static const double _stopRadiusM = 120.0;
  static const double _stopMaxSpeedMps = 1.0; // ~3.6 km/h — parked/stopped

  int get fixCount => fixes.length;

  /// Records spooled to disk so far (0 while spooling is unavailable).
  int get spooledRecords => _spool.written;

  /// Stop spooling and delete the `.part` files — called by [saveTrip] once the
  /// finished trip is safely on disk. Nothing else may call it: keeping the
  /// spool is the whole point when a save fails.
  Future<void> discardSpool() => _spool.discard();

  /// Stop spooling but KEEP the file (graceful shutdown, tests). Everything
  /// already spooled is on disk; [recoverSpooledTrips] can rebuild from it.
  Future<void> closeSpool() => _spool.close();

  bool get hasEnoughData => fixes.length >= 2;

  double get durationMinutes => fixes.isEmpty
      ? 0
      : fixes.last.time.difference(startedAt).inMinutes.toDouble();

  void addFix(
    LatLng pos, {
    double accuracyM = 10,
    double speedMps = 0,
    double? heading,
    String source = 'GPS',
    String? streetName,
    String? highway,
    int? speedLimit,
    int? limitEffective,
    String? limitSource,
    String? limitLayer,
    String? vehicle,
    bool? oneway,
    int? lanes,
    bool? divided,
    bool? urban,
  }) {
    if (fixes.isNotEmpty) {
      final last = fixes.last;
      final moved = distanceMeters(LatLng(last.lat, last.lng), pos);
      if (DateTime.now().difference(last.time) < _minInterval &&
          moved < _minDistance) {
        return; // too soon and too close — skip
      }
    }
    fixes.add(
      TripFix(
        time: DateTime.now(),
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyM: accuracyM,
        speedMps: speedMps,
        heading: heading,
        source: source,
        streetName: streetName,
        highway: highway,
        speedLimit: speedLimit,
        limitEffective: limitEffective,
        limitSource: limitSource,
        limitLayer: limitLayer,
        vehicle: vehicle,
        oneway: oneway,
        lanes: lanes,
        divided: divided,
        urban: urban,
      ),
    );
    // Track for place (stop) detection.
    _trackStop(pos, speedMps);
    // Continuous write: this fix is on disk NOW, so a kill / crash / battery
    // pull mid-drive loses at most the last second instead of the whole drive.
    _spool.add('f', fixes.last.toTakeout());
  }

  /// Record a voice announcement at [pos] (the car's current position).
  void logAnnouncement(LatLng pos, String text, {String kind = 'voice'}) {
    announcements.add(
      TripAnnouncement(
        time: DateTime.now(),
        lat: pos.latitude,
        lng: pos.longitude,
        kind: kind,
        text: text,
      ),
    );
    _spool.add('a', announcements.last.toJson());
  }

  _TripStopCluster? _pendingStop;

  /// Feed each fix into a small rolling stop detector. When the vehicle is
  /// slow for long enough, a place is recorded.
  void _trackStop(LatLng pos, double speedMps) {
    final now = fixes.last.time;
    _TripStopCluster? pending = _pendingStop;
    if (speedMps <= _stopMaxSpeedMps) {
      if (pending == null) {
        // A stationary cluster begins — anchor it at the current position.
        _pendingStop = _TripStopCluster(anchor: pos, first: now, last: now);
      } else {
        pending.last = now;
        // If the cluster drifted beyond the stop radius, reset the anchor.
        if (distanceMeters(pending.anchor, pos) > _stopRadiusM) {
          pending.anchor = pos;
          pending.first = now;
        }
      }
    } else {
      // Moving again (or never started). If the stationary stretch was long
      // enough, record the place.
      if (pending != null &&
          pending.last.difference(pending.first) >= _stopMinStillSeconds) {
        final mid = LatLng(pending.anchor.latitude, pending.anchor.longitude);
        final place = TripPlace(
          enteredAt: pending.first,
          leftAt: pending.last,
          lat: mid.latitude,
          lng: mid.longitude,
        );
        places.add(place);
        _spool.add('p', place.toJson());
      }
      _pendingStop = null;
    }
  }

  /// Close any still-open stop at the end of the trip (so the destination
  /// counts as a visited place too).
  void finish() {
    final pending = _pendingStop;
    if (pending != null) {
      final mid = LatLng(pending.anchor.latitude, pending.anchor.longitude);
      places.add(
        TripPlace(
          enteredAt: pending.first,
          leftAt: pending.last,
          lat: mid.latitude,
          lng: mid.longitude,
          name: places.isEmpty && name.isNotEmpty ? name : null,
        ),
      );
    } else if (places.isEmpty && fixes.isNotEmpty) {
      // If no intermediate stop triggered, record the arrival fix as the destination place.
      final last = fixes.last;
      places.add(
        TripPlace(
          enteredAt: fixes.first.time,
          leftAt: last.time,
          lat: last.lat,
          lng: last.lng,
          name: name.isNotEmpty ? name : null,
        ),
      );
    }
    _pendingStop = null;
  }

  /// Try to name each detected place from the bundled offline POI index
  /// (nearest POI within ~150 m). Called once before saving; places with no
  /// nearby named POI stay unnamed.
  Future<void> resolvePlaceNames() async {
    if (places.isEmpty) return;
    final cats = await loadOfflinePois();
    const Distance d = Distance();
    for (final p in places) {
      if (p.name != null && p.name!.isNotEmpty) continue;
      OfflinePoi? best;
      var bestM = 150.0;
      for (final c in cats) {
        for (final poi in c.items) {
          // Bounding-box pre-filter (~150m is ~0.0015 deg) before spherical geodesic
          if ((p.lat - poi.lat).abs() > 0.002 ||
              (p.lng - poi.lng).abs() > 0.002) {
            continue;
          }
          final m = d.as(LengthUnit.Meter, LatLng(p.lat, p.lng), poi.pos);
          if (m < bestM) {
            bestM = m;
            best = poi;
          }
        }
      }
      if (best != null) p.name = best.name;
    }
  }

  /// Serialize to the Google Takeout `Records.json` shape (kept for
  /// compatibility with existing timeline tools) plus a `places` array
  /// (name/enter/leave position) for the in-app Google-Timeline view.
  Map<String, dynamic> toTakeoutJson() => {
    'locations': [for (final f in fixes) f.toTakeout()],
    'endLocationDetails': [
      {
        'endTime': fixes.isEmpty
            ? startedAt.toUtc().toIso8601String()
            : fixes.last.time.toUtc().toIso8601String(),
      },
    ],
    'places': [for (final p in places) p.toJson()],
    'announcements': [for (final a in announcements) a.toJson()],
  };

  String get defaultFileName {
    final d = startedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final safe = name
        .replaceAll(RegExp(r'[^\p{L}\p{N} _-]+', unicode: true), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return '${d.year}-${two(d.month)}-${two(d.day)}_'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}_'
        '${safe.isEmpty ? 'trip' : safe}.json';
  }
}

/// Rolling stationary cluster used by [TripLogger] stop detection.
class _TripStopCluster {
  LatLng anchor;
  DateTime first;
  DateTime last;
  _TripStopCluster({
    required this.anchor,
    required this.first,
    required this.last,
  });
}

/// Directory where trip logs are stored (app documents/trips).
Future<Directory> tripsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/trips');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// CONTINUOUS WRITE — what keeps a drive that gets cut off mid-way.
///
/// The Takeout trip is ONE JSON document, so it can only be written whole, and
/// [saveTrip] runs when navigation STOPS. A trip killed before that (force
/// stop, OOM kill, crash, battery pull, phone reboot) was lost entirely.
///
/// Every record is therefore appended to `<trip>.part` as one JSON LINE and
/// flushed the moment it happens:
///
/// ```
/// ["f", {"timestampMs":"…","latitudeE7":…}]   fix
/// ["a", {"text":"Giới hạn 50 km/h",…}]       announcement
/// ["p", {"enteredAt":"…",…}]                   place (stop)
/// ```
///
/// Append-only + one record per line means a cutoff leaves every COMPLETE line
/// intact (a torn last line is simply dropped), and [recoverSpooledTrips]
/// turns it back into a normal trip file at the next launch. At ~1 Hz that is a
/// few hundred bytes and one flush per fix — negligible, and the only way the
/// last minutes of a killed drive survive.
class TripSpool {
  TripSpool({required this.fileName, this.dir});

  /// Finished trip file name (`…_name.json`); the spool is that + `.part`.
  final String fileName;

  /// Where to spool (tests inject a temp dir; the app uses [tripsDirectory]).
  final Directory? dir;

  Future<void> _chain = Future<void>.value();
  List<IOSink> _sinks = const [];
  List<String> _paths = const [];
  bool _closed = false;

  /// True when the spool could not be opened (no path_provider in unit tests,
  /// read-only storage, …). The app then keeps working from memory and
  /// [saveTrip] still writes the whole trip at the end.
  bool failed = false;

  /// Records spooled so far.
  int written = 0;

  bool get active => !_closed && !failed;

  /// Queue one record. Order is preserved (writes are chained) and the caller
  /// never awaits — a GPS fix must never block on the disk.
  void add(String kind, Map<String, dynamic> record) {
    if (!active) return;
    _chain = _chain.then((_) => _write(kind, record));
  }

  Future<void> _write(String kind, Map<String, dynamic> record) async {
    // NOTE: no `_closed` guard here — records queued before close() must still
    // reach the disk (close() awaits this chain before closing the sinks).
    // [add] is what refuses new work once the spool is closed.
    try {
      if (_sinks.isEmpty) _sinks = await _open();
      final line = jsonEncode([kind, record]);
      for (final s in _sinks) {
        s.writeln(line);
      }
      for (final s in _sinks) {
        // Flush every record: a buffered line is exactly what a kill loses.
        await s.flush();
      }
      written++;
    } catch (_) {
      // Spooling is best-effort — it must never break the in-memory trip or
      // the final save.
      failed = true;
    }
  }

  Future<List<IOSink>> _open() async {
    final base = dir ?? await tripsDirectory();
    if (!base.existsSync()) base.createSync(recursive: true);
    final paths = <String>['${base.path}/$fileName.part'];
    // Mirror the spool to the external files dir too: same reason as the
    // finished trip (readable over adb without a debug build), same one line
    // per fix.
    try {
      final ext = await _externalTripsDir(create: true);
      if (ext != null && ext.path != base.path) {
        paths.add('${ext.path}/$fileName.part');
      }
    } catch (_) {}
    _paths = paths;
    return [
      for (final p in paths) File(p).openWrite(mode: FileMode.writeOnlyAppend),
    ];
  }

  /// Stop writing and close the sinks. The files are KEPT — [discard] removes
  /// them, and only once the finished trip is on disk.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _chain;
    for (final s in _sinks) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  /// Close and delete the spool files (after a successful [saveTrip]).
  Future<void> discard() async {
    await close();
    for (final p in _paths) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
}

/// The app's EXTERNAL files dir (`/sdcard/Android/data/<pkg>/files/trips`), or
/// null when unavailable. No permission is needed for an app's own external
/// dir and it IS readable over USB/adb, unlike the private documents dir.
Future<Directory?> _externalTripsDir({bool create = false}) async {
  try {
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    final dir = Directory('${ext.path}/trips');
    if (create && !dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  } catch (_) {
    return null;
  }
}

/// Rebuild a trip (Takeout shape) from a `.part` spool: every complete line is
/// one record, so the drive is recovered up to the cutoff and a torn last line
/// is dropped. Returns null when no fix survived.
Map<String, dynamic>? decodeSpoolFile(File f) {
  final fixes = <Map<String, dynamic>>[];
  final places = <Map<String, dynamic>>[];
  final announcements = <Map<String, dynamic>>[];
  for (final raw in f.readAsStringSync().split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    Object? rec;
    try {
      rec = jsonDecode(line);
    } catch (_) {
      continue; // torn tail line — everything before it is still good
    }
    if (rec is! List || rec.length != 2 || rec[1] is! Map) continue;
    final body = Map<String, dynamic>.from(rec[1] as Map);
    switch (rec[0]) {
      case 'f':
        fixes.add(body);
      case 'p':
        places.add(body);
      case 'a':
        announcements.add(body);
    }
  }
  if (fixes.length < 2) return null; // same bar as [TripLogger.hasEnoughData]
  return {
    'locations': fixes,
    'endLocationDetails': [
      {'endTime': fixes.last['timestamp']},
    ],
    'places': places,
    'announcements': announcements,
    // Marks a salvaged trip, so a viewer/tool can say so instead of pretending
    // the drive ended where the app was killed.
    'recovered': true,
  };
}

/// Turn every left-over `<trip>.part` spool into a normal trip file.
///
/// A `.part` means a trip that never reached [saveTrip] — the app was killed
/// mid-drive (or the final write failed). Called at startup; returns how many
/// trips were recovered. The external copy is used only when the private one is
/// missing (a reinstall wipes the private dir), and both spool copies are
/// removed once the trip exists as a `.json`.
Future<int> recoverSpooledTrips({Directory? dir}) async {
  try {
    final trips = dir ?? await tripsDirectory();
    final parts = <File>[];
    if (trips.existsSync()) {
      parts.addAll(
        trips.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.part'),
        ),
      );
    }
    final ext = await _externalTripsDir();
    if (ext != null && ext.path != trips.path && ext.existsSync()) {
      final known = {for (final f in parts) f.uri.pathSegments.last};
      parts.addAll(
        ext
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.part'))
            .where((f) => !known.contains(f.uri.pathSegments.last)),
      );
    }

    var recovered = 0;
    for (final f in parts) {
      final base = f.uri.pathSegments.last;
      final name = base.substring(0, base.length - '.part'.length);
      final out = File('${trips.path}/$name');
      // A finished trip always wins: the spool is then just a leftover.
      if (!out.existsSync()) {
        final body = decodeSpoolFile(f);
        if (body == null) {
          // No complete fix line in it — nothing to rebuild, and leaving the
          // `.part` around would keep it in the scan forever.
          debugPrint('TRIP: discarded unusable spool $base');
        } else {
          final text = const JsonEncoder.withIndent('  ').convert(body);
          await out.writeAsString(text);
          await _mirrorToExternal(name, text);
          recovered++;
          debugPrint(
            'TRIP: recovered ${(body['locations'] as List).length} fixes '
            'from $base',
          );
        }
      }
      for (final p in [f, if (ext != null) File('${ext.path}/$base')]) {
        try {
          if (p.existsSync()) p.deleteSync();
        } catch (_) {}
      }
    }
    return recovered;
  } catch (_) {
    return 0;
  }
}

/// Write a trip to disk in Takeout Records.json format; returns the file.
///
/// Closes the pending stop (so the destination counts as a visited place) and
/// resolves each detected place's name from the offline POI index before
/// serializing. The continuous spool ([TripSpool]) is deleted only AFTER the
/// finished file is on disk — a failed save leaves it for [recoverSpooledTrips].
Future<File> saveTrip(TripLogger trip) async {
  trip.finish();
  try {
    await trip.resolvePlaceNames();
  } catch (_) {
    // POI lookup is best-effort; a failure must never lose the trip.
  }
  final body = const JsonEncoder.withIndent('  ').convert(trip.toTakeoutJson());
  final dir = await tripsDirectory();
  final file = File('${dir.path}/${trip.defaultFileName}');
  await file.writeAsString(body);
  await _mirrorToExternal(trip.defaultFileName, body);
  await trip.discardSpool(); // the trip is safe: the spool is a leftover now
  return file;
}

/// Mirror the trip into the app's EXTERNAL files dir
/// (`/sdcard/Android/data/<pkg>/files/trips`).
///
/// No permission is needed for an app's own external dir, it survives a
/// reinstall better than the private one, and unlike `getApplicationDocuments
/// Directory()` it is READABLE OVER USB/adb — which is the difference between
/// "send me that trip log" being one `adb pull` and having to install a
/// debug-signed build to get `run-as`.
Future<void> _mirrorToExternal(String name, String body) async {
  try {
    final dir = await _externalTripsDir(create: true);
    if (dir == null) return;
    await File('${dir.path}/$name').writeAsString(body);
  } catch (_) {
    // Best-effort mirror: the private copy is the authoritative one.
  }
}

/// All saved trips, newest first.
Future<List<File>> listTrips() async {
  final dir = await tripsDirectory();
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();
  files.sort((a, b) => b.path.compareTo(a.path));
  return files;
}

/// A date "bucket" header for the Google-Timeline-like trip list.
enum TripDateBucket { today, yesterday, thisWeek, older }

String tripDateBucketLabel(TripDateBucket b) => switch (b) {
  TripDateBucket.today => 'Hôm nay',
  TripDateBucket.yesterday => 'Hôm qua',
  TripDateBucket.thisWeek => 'Tuần này',
  TripDateBucket.older => 'Trước đó',
};

/// Classify [date] into a coarse bucket relative to [now] (local time).
TripDateBucket tripDateBucket(DateTime date, DateTime now) {
  final d = DateTime(date.year, date.month, date.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  if (diff <= 0) return TripDateBucket.today;
  if (diff == 1) return TripDateBucket.yesterday;
  if (diff < 7) return TripDateBucket.thisWeek;
  return TripDateBucket.older;
}

/// Human date label for a trip file (e.g. "06/09/2026"). Parses the date
/// from the YYYY-MM-DD_ prefix; falls back to the file mtime.
String tripDateLabel(File f) {
  final base = f.uri.pathSegments.last;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})_').firstMatch(base);
  if (m != null) {
    return '${m.group(3)}/${m.group(2)}/${m.group(1)}';
  }
  final t = f.statSync().modified.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}/${t.year}';
}

/// The local date a trip belongs to (parsed from the filename prefix).
DateTime? tripLocalDate(File f) {
  final base = f.uri.pathSegments.last;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})_').firstMatch(base);
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
}

/// Read the `places` array from a saved trip file (empty if none/legacy).
List<TripPlace> readTripPlaces(File f) {
  try {
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return [
      for (final p
          in (data['places'] as List? ?? const []).cast<Map<String, dynamic>>())
        TripPlace.fromJson(p),
    ];
  } catch (_) {
    return const [];
  }
}

/// Read the trip label (from the filename, after the timestamp prefix).
String readTripName(File f) {
  final base = f.uri.pathSegments.last;
  final m = RegExp(r'^\d{4}-\d{2}-\d{2}_\d{6}_(.+)\.json$').firstMatch(base);
  if (m != null) return m.group(1)!.replaceAll('_', ' ');
  return base;
}

/// A fully-loaded saved trip: the recorded GPS path plus the stops/places.
class LoadedTrip {
  final String name;
  final List<LatLng> path;
  final List<TripPlace> places;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const LoadedTrip({
    required this.name,
    required this.path,
    required this.places,
    this.startedAt,
    this.endedAt,
  });

  /// Total path length in km.
  double get distanceKm {
    var m = 0.0;
    for (var i = 0; i < path.length - 1; i++) {
      m += distanceMeters(path[i], path[i + 1]);
    }
    return m / 1000.0;
  }

  /// Trip duration (end − start); null when times are missing.
  Duration? get duration {
    final a = startedAt, b = endedAt;
    if (a == null || b == null) return null;
    return b.difference(a);
  }

  /// Average speed over the whole trip (km/h); null when duration is unknown
  /// or zero.
  double? get avgSpeedKmh {
    final d = duration;
    if (d == null || d.inSeconds == 0) return null;
    return distanceKm / (d.inSeconds / 3600.0);
  }

  /// Estimated fuel burned (litres) for [vehicle] ('car' | 'motorbike' |
  /// 'truck'), an order-of-magnitude estimate via [fuelRateL100].
  double estimatedFuelL(String vehicle) =>
      distanceKm * fuelRateL100(vehicle) / 100.0;
}

/// Read the full recorded path + places + times from a saved trip file, so
/// the trip can be re-drawn on a map.
///
/// [path] is the GPS-fix polyline (one lat/lng per recorded fix, in order);
/// empty when the file is unreadable or has no fixes.
Future<LoadedTrip> loadTrip(File f) async {
  final name = readTripName(f);
  try {
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final path = <LatLng>[];
    DateTime? startedAt;
    DateTime? endedAt;
    for (final loc in (data['locations'] as List? ?? const [])) {
      final m = (loc as Map<String, dynamic>);
      final latE7 = ((m['latitudeE7'] ?? 0) as num).toInt();
      final lngE7 = ((m['longitudeE7'] ?? 0) as num).toInt();
      if (latE7 == 0 && lngE7 == 0) continue;
      path.add(LatLng(latE7 / 1e7, lngE7 / 1e7));
      final ms = int.tryParse('${m['timestampMs']}');
      if (ms != null) {
        final t = DateTime.fromMillisecondsSinceEpoch(ms);
        startedAt ??= t;
        endedAt = t;
      }
    }
    final places = [
      for (final p
          in (data['places'] as List? ?? const []).cast<Map<String, dynamic>>())
        TripPlace.fromJson(p),
    ];
    return LoadedTrip(
      name: name,
      path: path,
      places: places,
      startedAt: startedAt,
      endedAt: endedAt,
    );
  } catch (_) {
    return LoadedTrip(name: name, path: const [], places: const []);
  }
}

/// Typical fuel use (litres / 100 km) for a vehicle type.
double fuelRateL100(String vehicle) {
  switch (vehicle) {
    case 'motorbike':
      return 2.5;
    case 'truck':
      return 20.0;
    default:
      return 7.5; // car / unknown
  }
}

/// Total path length (km) from a decoded Takeout `locations` list.
double tripPathKm(List<dynamic> locations) {
  var m = 0.0;
  LatLng? prev;
  for (final loc in locations) {
    final lm = loc as Map<String, dynamic>;
    final latE7 = ((lm['latitudeE7'] ?? 0) as num).toInt();
    final lngE7 = ((lm['longitudeE7'] ?? 0) as num).toInt();
    if (latE7 == 0 && lngE7 == 0) continue;
    final p = LatLng(latE7 / 1e7, lngE7 / 1e7);
    if (prev != null) m += distanceMeters(prev, p);
    prev = p;
  }
  return m / 1000.0;
}

/// Does a place name look like a refuelling (gas-station) stop? Matches
/// common Việt Nam brands / "cây xăng" wording.
bool isGasStationName(String name) {
  final n = name.toLowerCase();
  const kws = [
    'petrolimex',
    'pvoil',
    'shell',
    'castrol',
    'caltex',
    'esso',
    'idemitsu',
    'sagol',
    'trạm xăng',
    'trạm xang',
    'cây xăng',
    'cây xang',
    'cửa hàng xăng',
    'xăng dầu',
  ];
  return kws.any((k) => n.contains(k));
}

/// Number of recorded stops that appear to be refuelling stops (gas station).
int gasStationStopCount(LoadedTrip t) =>
    t.places.where((p) => isGasStationName(p.name ?? '')).length;
