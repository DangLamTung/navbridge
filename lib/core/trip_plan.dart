/// Multi-stop trip plans ("predefined trips") — saved to disk and loadable
/// for one-tap navigation, including fully offline.
library;

import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

class TripStop {
  final String name;
  final double lat;
  final double lng;

  TripStop({required this.name, required this.lat, required this.lng});

  LatLng get pos => LatLng(lat, lng);

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lng': lng};

  factory TripStop.fromJson(Map<String, dynamic> j) => TripStop(
    name: (j['name'] ?? '') as String,
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
  );
}

class TripPlan {
  final String name;
  final DateTime createdAt;
  final List<TripStop> stops;

  /// Optional routing metadata saved with the plan (favourite route):
  /// `RouteProfile.name` / `RoutePreference.name` + the avoid flags, so a
  /// saved plan can be re-routed the same way. Null = legacy plan.
  final String? profile;
  final String? preference;
  final bool avoidHighway;
  final bool avoidFerry;

  TripPlan({
    required this.name,
    required this.createdAt,
    required this.stops,
    this.profile,
    this.preference,
    this.avoidHighway = false,
    this.avoidFerry = false,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'stops': [for (final s in stops) s.toJson()],
    if (profile != null) 'profile': profile,
    if (preference != null) 'preference': preference,
    if (avoidHighway) 'avoidHighway': true,
    if (avoidFerry) 'avoidFerry': true,
  };

  factory TripPlan.fromJson(Map<String, dynamic> j) => TripPlan(
    name: (j['name'] ?? 'Kế hoạch') as String,
    createdAt:
        DateTime.tryParse((j['createdAt'] ?? '') as String) ?? DateTime.now(),
    stops: [
      for (final s in (j['stops'] as List? ?? []).cast<Map<String, dynamic>>())
        TripStop.fromJson(s),
    ],
    profile: j['profile'] as String?,
    preference: j['preference'] as String?,
    avoidHighway: j['avoidHighway'] == true,
    avoidFerry: j['avoidFerry'] == true,
  );
}

Future<File> _plansFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/plans.json');
}

Future<List<TripPlan>> loadPlans() async {
  final f = await _plansFile();
  if (!f.existsSync()) return [];
  try {
    final data = jsonDecode(f.readAsStringSync()) as List;
    return data
        .map((e) => TripPlan.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> savePlans(List<TripPlan> plans) async {
  final f = await _plansFile();
  await f.writeAsString(
    jsonEncode([for (final p in plans) p.toJson()]),
    flush: true,
  );
}
