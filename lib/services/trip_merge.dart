/// Merge every saved trip of one day into a single Takeout-format file.
///
/// The trips screen already groups a day visually; this is the data merge: all
/// fixes are sorted by time, duplicate fixes at the same timestamp are dropped,
/// and pauses longer than [maxGap] become break indices so the map draws one
/// polyline per continuous drive instead of a straight line across the stop.
///
/// The original files are moved to `trips/originals/` (not deleted), and the
/// trip backup includes that folder, so a merge is reversible.
library;

import 'dart:convert';
import 'dart:io';

import 'trip_logger.dart';

/// Result of [mergeTripsForDay].
class TripMergeResult {
  final File file;
  final int sourceCount;
  final int pointCount;
  final int breakCount;

  const TripMergeResult({
    required this.file,
    required this.sourceCount,
    required this.pointCount,
    required this.breakCount,
  });
}

/// Merge all top-level trips whose filename date is [day]. Returns null when
/// there is nothing to merge (fewer than two source files or no fixes).
Future<TripMergeResult?> mergeTripsForDay(
  DateTime day, {
  Duration maxGap = const Duration(minutes: 30),
}) async {
  final wanted = DateTime(day.year, day.month, day.day);
  final files = <File>[];
  for (final f in await listTrips()) {
    final d = tripLocalDate(f);
    if (d == null) continue;
    if (d.year == wanted.year &&
        d.month == wanted.month &&
        d.day == wanted.day) {
      files.add(f);
    }
  }
  if (files.length < 2) return null;

  final docs = <Map<String, dynamic>>[];
  final names = <String>[];
  for (final f in files) {
    try {
      final doc = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      docs.add(doc);
      names.add(f.uri.pathSegments.last);
    } catch (_) {
      // A corrupt trip must not block merging the others.
    }
  }
  if (docs.length < 2) return null;

  final merged = mergeTripDocuments(
    docs,
    maxGap: maxGap,
    sourceNames: names,
  );
  final points = merged['locations'] as List;
  if (points.isEmpty) return null;

  final dir = await tripsDirectory();
  String two(int n) => n.toString().padLeft(2, '0');
  final name =
      '${wanted.year}-${two(wanted.month)}-${two(wanted.day)}_000000_'
      'Gộp_ngày.json';
  final out = await _uniqueFile(dir, name);
  final tmp = File('${out.path}.tmp');
  await tmp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(merged),
    flush: true,
  );
  await tmp.rename(out.path);

  final archive = await archivedTripsDirectory();
  for (final f in files) {
    final target = await _uniqueFile(archive, f.uri.pathSegments.last);
    await f.rename(target.path);
  }

  return TripMergeResult(
    file: out,
    sourceCount: files.length,
    pointCount: points.length,
    breakCount: ((merged['breaks'] as List?) ?? const []).length,
  );
}

/// Pure merge used by [mergeTripsForDay] and unit tests.
Map<String, dynamic> mergeTripDocuments(
  List<Map<String, dynamic>> docs, {
  Duration maxGap = const Duration(minutes: 30),
  List<String> sourceNames = const [],
}) {
  final entries = <_Point>[];
  final places = <String, Map<String, dynamic>>{};
  final announcements = <String, Map<String, dynamic>>{};
  final rawFixes = <String, Map<String, dynamic>>{};
  var order = 0;

  for (var d = 0; d < docs.length; d++) {
    final doc = docs[d];
    for (final loc in (doc['locations'] as List? ?? const [])) {
      if (loc is! Map) continue;
      entries.add(_Point(loc.cast<String, dynamic>(), d, order++));
    }
    for (final p in (doc['places'] as List? ?? const [])) {
      if (p is! Map) continue;
      final m = p.cast<String, dynamic>();
      places.putIfAbsent([m['lat'], m['lng'], m['enteredAt']].join('|'), () => m);
    }
    for (final a in (doc['announcements'] as List? ?? const [])) {
      if (a is! Map) continue;
      final m = a.cast<String, dynamic>();
      announcements.putIfAbsent(
        [m['timestampMs'], m['kind'], m['text']].join('|'),
        () => m,
      );
    }
    for (final r in (doc['rawFixes'] as List? ?? const [])) {
      if (r is! Map) continue;
      final m = r.cast<String, dynamic>();
      rawFixes.putIfAbsent(
        [m['timestampMs'], m['latitudeE7'], m['longitudeE7']].join('|'),
        () => m,
      );
    }
  }

  entries.sort((a, b) {
    final byTime = a.ms.compareTo(b.ms);
    if (byTime != 0) return byTime;
    final byDoc = a.doc.compareTo(b.doc);
    if (byDoc != 0) return byDoc;
    return a.order.compareTo(b.order);
  });

  final locations = <Map<String, dynamic>>[];
  final breaks = <int>[];
  final seen = <String>{};
  int? previousMs;
  for (final e in entries) {
    final key = e.ms > 0
        ? 't:${e.ms}'
        : 'p:${e.loc['latitudeE7']}:${e.loc['longitudeE7']}';
    if (!seen.add(key)) continue;
    if (previousMs != null &&
        e.ms > 0 &&
        e.ms - previousMs > maxGap.inMilliseconds) {
      breaks.add(locations.length);
    }
    if (e.ms > 0) previousMs = e.ms;
    locations.add(e.loc);
  }

  final orderedPlaces = places.values.toList()
    ..sort(
      (a, b) => '${a['enteredAt']}'.compareTo('${b['enteredAt']}'),
    );
  final orderedAnnouncements = announcements.values.toList()
    ..sort((a, b) => _ms(a).compareTo(_ms(b)));
  final orderedRaw = rawFixes.values.toList()
    ..sort((a, b) => _ms(a).compareTo(_ms(b)));

  final endMs = locations.isEmpty ? null : _ms(locations.last);
  return {
    'locations': locations,
    if (breaks.isNotEmpty) 'breaks': breaks,
    if (breaks.isNotEmpty) 'breakGapMinutes': maxGap.inMinutes,
    'endLocationDetails': [
      {
        'endTime': endMs == null
            ? DateTime.now().toUtc().toIso8601String()
            : DateTime.fromMillisecondsSinceEpoch(
                endMs,
              ).toUtc().toIso8601String(),
      },
    ],
    'places': orderedPlaces,
    'announcements': orderedAnnouncements,
    if (orderedRaw.isNotEmpty) 'rawFixes': orderedRaw,
    if (sourceNames.isNotEmpty) 'mergedFrom': sourceNames,
    'mergedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

class _Point {
  final Map<String, dynamic> loc;
  final int doc;
  final int order;
  final int ms;

  _Point(this.loc, this.doc, this.order) : ms = _ms(loc);
}

int _ms(Map<String, dynamic> j) {
  final raw = j['timestampMs'];
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? 0;
}

Future<File> _uniqueFile(Directory dir, String name) async {
  var f = File('${dir.path}/$name');
  if (!await f.exists()) return f;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; ; i++) {
    f = File('${dir.path}/${stem}_$i$ext');
    if (!await f.exists()) return f;
  }
}
