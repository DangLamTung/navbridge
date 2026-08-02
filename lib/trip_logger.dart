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
///       "activity": [ { "type": "IN_VEHICLE", "confidence": 100 } ] } ] }
/// ] }
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'osrm.dart' show distanceMeters;

/// One recorded fix (mirrors a Google Takeout `locations` entry).
class TripFix {
  final DateTime time;
  final double lat;
  final double lng;
  final double accuracyM; // meters
  final double speedMps; // m/s (0 when unknown)
  final String source; // 'GPS' | 'SIM'

  TripFix({
    required this.time,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.speedMps,
    required this.source,
  });

  Map<String, dynamic> toTakeout() {
    final ms = time.millisecondsSinceEpoch.toString();
    return {
      'timestampMs': ms,
      'latitudeE7': (lat * 1e7).round(),
      'longitudeE7': (lng * 1e7).round(),
      'accuracy': accuracyM.round(),
      'source': source,
      'activity': [
        {
          'timestampMs': ms,
          'activity': [
            {
              'type': speedMps > 2 ? 'IN_VEHICLE' : 'STILL',
              'confidence': 100,
            },
          ],
        },
      ],
    };
  }
}

/// A single recording session. Sample like Google does: at most one fix every
/// 5 s unless the position moved more than 20 m.
class TripLogger {
  final String name; // trip label (usually the destination)
  final DateTime startedAt;
  final List<TripFix> fixes = [];

  TripLogger({required this.name, DateTime? startedAt})
      : startedAt = startedAt ?? DateTime.now();

  static const Duration _minInterval = Duration(seconds: 5);
  static const double _minDistance = 20.0;

  int get fixCount => fixes.length;

  bool get hasEnoughData => fixes.length >= 2;

  double get durationMinutes => fixes.isEmpty
      ? 0
      : fixes.last.time.difference(startedAt).inMinutes.toDouble();

  void addFix(
    LatLng pos, {
    double accuracyM = 10,
    double speedMps = 0,
    String source = 'GPS',
  }) {
    if (fixes.isNotEmpty) {
      final last = fixes.last;
      final moved = distanceMeters(
          LatLng(last.lat, last.lng), pos);
      if (DateTime.now().difference(last.time) < _minInterval &&
          moved < _minDistance) {
        return; // too soon and too close — skip
      }
    }
    fixes.add(TripFix(
      time: DateTime.now(),
      lat: pos.latitude,
      lng: pos.longitude,
      accuracyM: accuracyM,
      speedMps: speedMps,
      source: source,
    ));
  }

  /// Serialize to the Google Takeout `Records.json` shape.
  Map<String, dynamic> toTakeoutJson() => {
        'locations': [for (final f in fixes) f.toTakeout()],
        'endLocationDetails': [
          {
            'endTime': fixes.isEmpty
                ? startedAt.toIso8601String()
                : fixes.last.time.toIso8601String(),
          },
        ],
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

/// Directory where trip logs are stored (app documents/trips).
Future<Directory> tripsDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/trips');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Write a trip to disk in Takeout Records.json format; returns the file.
Future<File> saveTrip(TripLogger trip) async {
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
