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

  TripPlan({required this.name, required this.createdAt, required this.stops});

  Map<String, dynamic> toJson() => {
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'stops': [for (final s in stops) s.toJson()],
      };

  factory TripPlan.fromJson(Map<String, dynamic> j) => TripPlan(
        name: (j['name'] ?? 'Kế hoạch') as String,
        createdAt:
            DateTime.tryParse((j['createdAt'] ?? '') as String) ?? DateTime.now(),
        stops: [
          for (final s
              in (j['stops'] as List? ?? []).cast<Map<String, dynamic>>())
            TripStop.fromJson(s)
        ],
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
  await f.writeAsString(jsonEncode([for (final p in plans) p.toJson()]),
      flush: true);
}
