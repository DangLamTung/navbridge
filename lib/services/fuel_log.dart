/// Manual fuel (refuel) logging — you record how much gas you put in each
/// time, so the app can show the ACTUAL fuel used for a trip instead of a
/// distance-based estimate. Entries are persisted to a small `fuel_log.json`
/// in the app-support directory and can optionally be tied to a trip file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// One refuel event.
class FuelEntry {
  final DateTime time;
  final double liters;
  final double? cost; // VND, optional
  final String? tripFile; // path of the trip this fill belongs to (optional)

  const FuelEntry({
    required this.time,
    required this.liters,
    this.cost,
    this.tripFile,
  });

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'liters': liters,
    if (cost != null) 'cost': cost,
    if (tripFile != null) 'tripFile': tripFile,
  };

  factory FuelEntry.fromJson(Map<String, dynamic> j) => FuelEntry(
    time: DateTime.tryParse((j['time'] ?? '') as String) ?? DateTime.now(),
    liters: ((j['liters'] ?? 0) as num).toDouble(),
    cost: (j['cost'] as num?)?.toDouble(),
    tripFile: j['tripFile'] as String?,
  );
}

Future<File> _fuelFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/fuel_log.json');
}

/// All refuel entries, oldest first. Empty on any error.
Future<List<FuelEntry>> loadFuelLog() async {
  try {
    final f = await _fuelFile();
    if (!f.existsSync()) return [];
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return [
      for (final e in (data['entries'] as List? ?? const [])
          .cast<Map<String, dynamic>>())
        FuelEntry.fromJson(e),
    ]..sort((a, b) => a.time.compareTo(b.time));
  } catch (_) {
    return [];
  }
}

/// Append [e] and persist; returns the updated (sorted) log.
Future<List<FuelEntry>> addFuelEntry(FuelEntry e) async {
  final log = await loadFuelLog();
  log.add(e);
  log.sort((a, b) => a.time.compareTo(b.time));
  final f = await _fuelFile();
  await f.writeAsString(
    jsonEncode({'entries': [for (final x in log) x.toJson()]}),
    flush: true,
  );
  return log;
}

bool _matchesTrip(String? entryFile, String tripPath) {
  if (entryFile == null || tripPath.isEmpty) return entryFile == tripPath;
  if (entryFile == tripPath) return true;
  final eBase = entryFile.split('/').last.split(r'\').last;
  final tBase = tripPath.split('/').last.split(r'\').last;
  return eBase.isNotEmpty && eBase == tBase;
}

/// Total litres logged for [tripPath] ('' matches untagged fills).
double fuelLitersForTrip(List<FuelEntry> log, String tripPath) {
  var s = 0.0;
  for (final e in log) {
    if (_matchesTrip(e.tripFile, tripPath)) s += e.liters;
  }
  return s;
}

/// Number of refuel stops logged for [tripPath].
int fuelStopsForTrip(List<FuelEntry> log, String tripPath) =>
    log.where((e) => _matchesTrip(e.tripFile, tripPath)).length;
