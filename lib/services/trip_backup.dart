/// Backup / restore of all recorded trips + the manual fuel log, so they can
/// survive an app reinstall (which wipes the app's private data).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'fuel_log.dart';
import 'trip_logger.dart';

/// Export every saved trip + the fuel log into a single JSON file (in the app
/// documents dir). Returns the file, ready to share.
Future<File> exportTripsBackup() async {
  final trips = <Map<String, dynamic>>[];
  for (final f in await listTrips()) {
    try {
      final content = jsonDecode(await f.readAsString());
      trips.add({'file': f.uri.pathSegments.last, 'data': content});
    } catch (_) {}
  }
  final fuelLog = await loadFuelLog();
  final backup = {
    'app': 'navbridge',
    'version': 1,
    'exportedAt': DateTime.now().toIso8601String(),
    'trips': trips,
    'fuelLog': [for (final e in fuelLog) e.toJson()],
  };
  final docs = await getApplicationDocumentsDirectory();
  final file = File(
    '${docs.path}/navbridge_backup_${DateTime.now().millisecondsSinceEpoch}.json',
  );
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(backup));
  return file;
}

/// Share the backup file (send to Drive / email / save to Files, etc.).
Future<void> shareTripsBackup() async {
  final f = await exportTripsBackup();
  await Share.shareXFiles(
    [XFile(f.path, mimeType: 'application/json')],
    text: 'NavBridge backup — all trips + fuel log',
  );
}

/// Restore trips + fuel log from a backup [file]. Returns the number of trips
/// restored.
Future<int> restoreTripsBackup(File file) async {
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final dir = await tripsDirectory();
  var restored = 0;
  for (final t in (data['trips'] as List? ?? const [])
      .cast<Map<String, dynamic>>()) {
    final name = (t['file'] ?? 'trip.json') as String;
    final content = t['data'];
    if (content == null) continue;
    // Avoid path traversal / collisions from an untrusted filename.
    final safe = name.replaceAll(RegExp(r'[^\w.\-]', unicode: true), '_');
    await File('${dir.path}/$safe')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(content));
    restored++;
  }
  for (final e in (data['fuelLog'] as List? ?? const [])
      .cast<Map<String, dynamic>>()) {
    await addFuelEntry(FuelEntry.fromJson(e));
  }
  return restored;
}
