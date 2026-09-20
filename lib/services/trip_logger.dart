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
library;

import 'dart:convert';
import 'dart:io';

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

  TripLogger({required this.name, DateTime? startedAt})
    : startedAt = startedAt ?? DateTime.now();

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
      ),
    );
    // Track for place (stop) detection.
    _trackStop(pos, speedMps);
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
        places.add(
          TripPlace(
            enteredAt: pending.first,
            leftAt: pending.last,
            lat: mid.latitude,
            lng: mid.longitude,
          ),
        );
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

/// Write a trip to disk in Takeout Records.json format; returns the file.
///
/// Closes the pending stop (so the destination counts as a visited place) and
/// resolves each detected place's name from the offline POI index before
/// serializing.
Future<File> saveTrip(TripLogger trip) async {
  trip.finish();
  try {
    await trip.resolvePlaceNames();
  } catch (_) {
    // POI lookup is best-effort; a failure must never lose the trip.
  }
  final dir = await tripsDirectory();
  final file = File('${dir.path}/${trip.defaultFileName}');
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(trip.toTakeoutJson()),
  );
  return file;
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
