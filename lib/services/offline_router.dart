/// On-device offline routing via GraphHopper (MethodChannel → Kotlin).
///
/// A pre-built car graph (a `.ghz` zip or an extracted folder) is downloaded
/// once and loaded into GraphHopper on the device; then any A→B (or multi-stop)
/// route can be computed fully offline, including re-routing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_tiles.dart' show forceOffline;
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/core/route_profile.dart';
import 'vietmap_config.dart' show graphDownloadBaseUrl;
import 'package:navbridge/services/vietmap_router.dart';
import 'package:navbridge/services/google_router.dart';
import 'package:navbridge/services/api_notice.dart' show noteRouteFallback;
import 'package:navbridge/services/route_providers.dart';

const MethodChannel _channel = MethodChannel('navbridge/routing');

/// Result of snapping a GPS fix to the nearest road in the offline graph
/// (network matching — like Google Maps' blue dot snapping to the road).
class SnapResult {
  final double lat;
  final double lng;
  final double distance; // meters from the fix to the road
  final int edge; // graph edge id of the snapped road
  const SnapResult({
    required this.lat,
    required this.lng,
    required this.distance,
    required this.edge,
  });
}

/// A `.ghz` built on the phone by [OfflineRouter.buildGraphArchive].
class GraphArchiveResult {
  /// Absolute path of the written archive.
  final String path;

  /// Size of the archive in bytes.
  final int bytes;

  /// Total size of the graph files that went into it — the two together say how
  /// much space the archive costs versus the folder it duplicates.
  final int sourceBytes;

  const GraphArchiveResult({
    required this.path,
    required this.bytes,
    required this.sourceBytes,
  });
}

/// Copying the archive to Downloads needs storage permission (Android 8–9 only;
/// on API 29+ MediaStore handles it silently). The UI asks for it and retries.
class GraphExportNeedsPermission implements Exception {
  @override
  String toString() => 'Cần quyền ghi bộ nhớ để xuất tệp.';
}

class OfflineRouter {
  OfflineRouter._();

  static final OfflineRouter instance = OfflineRouter._();

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// True when the last load failed because the folder on the phone is a
  /// half-written graph (no `GH` marker in `properties`) rather than absent.
  /// The two need different advice: one is "download data", the other is
  /// "delete this and start again".
  bool _corrupt = false;
  bool get graphCorrupt => _corrupt;

  Completer<void>? _loadCompleter;

  /// Set while a `.ghz` is being built, so the native `buildProgress` calls land
  /// on the screen that started the build. The channel is shared with routing,
  /// so the handler must not disturb anything else.
  void Function(int done, int total)? _archiveProgress;
  bool _progressHandlerInstalled = false;

  void _installProgressHandler() {
    if (_progressHandlerInstalled) return;
    _progressHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'buildProgress') {
        final m = call.arguments;
        if (m is Map) {
          final done = (m['done'] as num?)?.toInt() ?? 0;
          final total = (m['total'] as num?)?.toInt() ?? 0;
          _archiveProgress?.call(done, total);
        }
      }
      return null;
    });
  }

  /// Completes once the graph has finished loading (or failed to load).
  /// Offline routing awaits this so it doesn't fail while the graph is still
  /// loading at startup (it can take ~60 s on low-end phones).
  Future<void> get ready {
    if (_loaded) return Future.value();
    final c = _loadCompleter;
    if (c == null) return Future.value();
    return c.future;
  }

  /// Load the graph at [graphPath] (a folder, or a `.ghz` zip — the native
  /// side extracts it). Returns true when routing is ready.
  Future<bool> load(String graphPath) async {
    // Reset every attempt: after a failed load the completer must not stay
    // completed, or [ready] would report "done" before the graph loaded.
    _loadCompleter = Completer<void>();
    try {
      final ok = await _channel.invokeMethod<bool>('load', {'dir': graphPath});
      _loaded = ok ?? false;
      _corrupt = false;
      if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
      return _loaded;
    } on PlatformException catch (e) {
      // `graph_corrupt` is the native side's marker check refusing a folder
      // that GraphHopper would only reject with a storage-layer stack trace.
      _corrupt = e.code == 'graph_corrupt';
      debugPrint('ROUTER: load error (${e.code}): ${e.message}');
      if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
      return false;
    } catch (e) {
      debugPrint('ROUTER: load error: $e');
      if (!_loadCompleter!.isCompleted) _loadCompleter!.complete();
      return false;
    }
  }

  /// Unload the routing engine and release file handles.
  Future<void> unload() async {
    try {
      await _channel.invokeMethod('unload');
    } catch (_) {}
    _loaded = false;
    _loadCompleter = null;
  }

  /// Ask the native side whether a graph is already loaded (e.g. after the
  /// process restarted).
  Future<bool> refreshLoaded() async {
    try {
      _loaded = await _channel.invokeMethod<bool>('isLoaded') ?? false;
    } catch (_) {}
    return _loaded;
  }

  /// Road info (name / road class / maxspeed) at [pos] straight from the
  /// on-device graph — instant and offline. Returns null when unavailable.
  Future<Map<String, dynamic>?> roadInfo(
    LatLng pos, {
    double? headingDeg,
  }) async {
    if (!_loaded) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('roadInfo', {
        'lat': pos.latitude,
        'lng': pos.longitude,
        // The car's heading, so the graph can reject an edge that runs ACROSS
        // the car's path (a crossing street is metres away at a junction) — the
        // Overpass road lookup already scores by heading, the graph did not.
        'heading': ?headingDeg,
      });
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw as Map);
    } catch (e) {
      debugPrint('ROUTER: roadInfo error: $e');
      return null;
    }
  }

  /// Google-style network match: snap [pos] to the nearest ROAD in the
  /// offline graph. Returns the snapped point + the graph edge id (so the
  /// caller can tell whether that road is part of the current route), or
  /// null when no road is nearby. Instant + offline.
  Future<SnapResult?> snapToRoad(LatLng pos) async {
    if (!_loaded) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('snapToRoad', {
        'lat': pos.latitude,
        'lng': pos.longitude,
      });
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      final edge = (m['edge'] as num?)?.toInt();
      if (lat == null || lng == null || edge == null) return null;
      return SnapResult(
        lat: lat,
        lng: lng,
        distance: (m['distance'] as num?)?.toDouble() ?? 0,
        edge: edge,
      );
    } catch (e) {
      debugPrint('ROUTER: snapToRoad error: $e');
      return null;
    }
  }

  /// Compute up to [maxAlternatives] routes through [points] (2+) entirely
  /// on-device (best first). [avoidMotorway]/[avoidFerry] block those road
  /// classes via a GraphHopper custom model. Returns [] when unavailable.
  Future<List<OsrmRoute>> route(
    List<LatLng> points, {
    int maxAlternatives = 1,
    bool avoidMotorway = false,
    bool avoidFerry = false,
    double? startHeading,
  }) async {
    if (points.length < 2 || !_loaded) return const [];
    try {
      final flat = <double>[];
      for (final p in points) {
        flat.add(p.latitude);
        flat.add(p.longitude);
      }
      final args = <String, dynamic>{
        'points': flat,
        'alternatives': maxAlternatives,
        'avoidMotorway': avoidMotorway,
        'avoidFerry': avoidFerry,
      };
      if (startHeading != null) args['heading'] = startHeading;
      // Platform-channel maps decode as Map<Object?, Object?>, so a typed
      // invokeMapMethod<String, dynamic> cast throws. Convert explicitly.
      final raw = await _channel
          .invokeMethod<Object?>('route', args)
          .timeout(const Duration(seconds: 90));
      if (raw == null) {
        debugPrint('ROUTER: route returned null (no path)');
        return const [];
      }
      // Kotlin returns a plain List of Maps (best first).
      final rawList = (raw as List).cast<Object?>();
      debugPrint('ROUTER: offline route paths=${rawList.length}');
      return [
        for (final r in rawList) _parse(Map<String, dynamic>.from(r as Map)),
      ];
    } on TimeoutException {
      debugPrint('ROUTER: offline route TIMED OUT (90s)');
      return const [];
    } catch (e) {
      debugPrint('ROUTER: route error: $e');
      return const [];
    }
  }

  OsrmRoute _parse(Map<String, dynamic> res) {
    final flat = (res['points'] as List).cast<num>();
    final geometry = <LatLng>[];
    for (var i = 0; i + 1 < flat.length; i += 2) {
      geometry.add(LatLng(flat[i].toDouble(), flat[i + 1].toDouble()));
    }
    // Steps arrive as List<Map<Object?, Object?>> — convert each explicitly
    // (List.cast<Map<String, dynamic>>() would throw on iteration).
    final rawSteps = (res['steps'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final steps = <OsrmStep>[];
    for (final s in rawSteps) {
      final sign = ((s['sign'] ?? 0) as num).toInt();
      final (type, modifier) = osrmManeuverForInstructionSign(sign);
      steps.add(
        OsrmStep(
          name: (s['name'] ?? '') as String,
          distance: ((s['distance'] ?? 0) as num).toDouble(),
          duration: ((s['duration'] ?? 0) as num).toDouble(),
          type: type,
          modifier: modifier,
          maneuver: LatLng(
            ((s['lat'] ?? 0) as num).toDouble(),
            ((s['lng'] ?? 0) as num).toDouble(),
          ),
        ),
      );
    }
    // Stop boundaries: instructions with sign 5 (REACHED_VIA) / 4 (FINISH).
    final stopCum = <double>[];
    var c = 0.0;
    for (final s in rawSteps) {
      final sign = ((s['sign'] ?? 0) as num).toInt();
      c += ((s['distance'] ?? 0) as num).toDouble();
      if (sign == 5 || sign == 4) stopCum.add(c);
    }
    if (stopCum.isEmpty && c > 0) stopCum.add(c);
    return OsrmRoute(
      distance: ((res['distance'] ?? 0) as num).toDouble(),
      duration: ((res['duration'] ?? 0) as num).toDouble(),
      geometry: geometry,
      steps: steps,
      stopCumulative: stopCum,
    );
  }

  // GraphHopper instruction sign → OSRM-style maneuver is shared with the
  // VietMap router: osrmManeuverForInstructionSign (core/nav_protocol.dart).
}

// ---- graph storage / download -------------------------------------------

/// Folder that holds the extracted GraphHopper graph.
Future<String> routingGraphDir() async {
  final sup = await getApplicationSupportDirectory();
  return '${sup.path}/routing_graph';
}

/// Delete the on-device routing graph and all downloaded source files to free phone storage.
Future<void> deleteRoutingGraph() async {
  await OfflineRouter.instance.unload();
  final dir = await routingGraphDir();
  final d = Directory(dir);
  if (d.existsSync()) {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  }
  for (final ext in ['.ghz', '.osm.pbf', '.pbf', '.zip']) {
    final f = File('$dir$ext');
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

/// GraphHopper marks its `properties` file with the ASCII pair `GH`, preceded by a
/// two-byte field — a real graph starts `00 02 47 48`, so the marker is **not at
/// offset 0**.
///
/// Getting that wrong is expensive: the first version of this check tested
/// offset 0, so every *valid* graph read as "debris" and [loadBestGraph] would
/// have deleted a good 452 MB graph folder on the next heal. The pair is now
/// sought in the first 8 bytes.
///
/// A folder whose `properties` is missing or empty IS debris — the debris of an
/// interrupted import, which creates the file first and can be killed before it
/// writes anything (seen on the itel_P663LN: a 249.6 MB folder with an empty
/// `properties` kept offline routing dead while the UI reported "data present").
bool graphPropertiesMarkerOk(File properties) {
  if (!properties.existsSync()) return false;
  try {
    final raf = properties.openSync();
    try {
      final head = raf.readSync(8);
      for (var i = 0; i + 1 < head.length; i++) {
        if (head[i] == 0x47 && head[i + 1] == 0x48) return true; // 'G','H'
      }
      return false;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Whether [dir] holds a graph GraphHopper can open.
///
/// Looks at `properties` in the folder itself, and one level down: a `.ghz` whose
/// entries keep a wrapper directory extracts to `dir/<wrapper>/properties`, and
/// calling that "debris" would let the self-healing loader delete a perfectly
/// good graph. Debris from an interrupted import is the other shape — a
/// `properties` at the ROOT that is present but carries no marker.
bool graphFolderLoadable(Directory dir) {
  if (graphPropertiesMarkerOk(File('${dir.path}/properties'))) return true;
  try {
    for (final e in dir.listSync()) {
      if (e is Directory &&
          graphPropertiesMarkerOk(File('${e.path}/properties'))) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

/// Whether the graph folder on the phone exists but cannot load.
///
/// False when there is no folder or it is empty — that is "not installed", a
/// different state with a different fix.
Future<bool> graphFolderCorrupt([String? dirPath]) async {
  final dir = Directory(dirPath ?? await routingGraphDir());
  if (!dir.existsSync()) return false;
  try {
    if (dir.listSync().isEmpty) return false;
  } catch (_) {
    return false;
  }
  return !graphFolderLoadable(dir);
}

/// Whether [f] is a COMPLETE zip archive, judged by its end-of-central-directory
/// record.
///
/// The cheap check that stops a truncated archive from reaching GraphHopper,
/// which can only say `zip END header not found` after being handed the file.
/// Seen on the itel_P663LN: the app adopted a `.ghz` while `adb push` was still
/// writing it, copied a partial file, and deleted the source — leaving a file
/// that was the right name and the right size to look plausible, and unusable.
bool zipComplete(File f) {
  try {
    final len = f.lengthSync();
    if (len < 22) return false;
    final raf = f.openSync();
    try {
      final window = len < 65536 ? len : 65536;
      raf.setPositionSync(len - window);
      final tail = raf.readSync(window);
      // 'PK\x05\x06' — scan back, a valid archive may carry a trailing comment.
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          return true;
        }
      }
      return false;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Delete sibling archives that are not complete zips. They cannot be used by
/// anything, and leaving them makes every load fail forever.
void dropIncompleteArchives(String dir) {
  for (final ext in ['.ghz', '.zip']) {
    final f = File('$dir$ext');
    if (!f.existsSync()) continue;
    if (zipComplete(f)) continue;
    try {
      f.deleteSync();
      debugPrint('ROUTER: dropped incomplete archive ${f.path}');
    } catch (e) {
      debugPrint('ROUTER: could not drop ${f.path}: $e');
    }
  }
}

/// The archive/source sitting beside the graph folder, best first: `.ghz` first
/// because unzipping is minutes faster than importing a PBF. Incomplete archives
/// are left out — a half-written `.ghz` must never be chosen.
List<String> graphSiblingSources(String dir) {
  final out = <String>[];
  for (final ext in ['.ghz', '.zip']) {
    final f = File('$dir$ext');
    if (f.existsSync() && zipComplete(f)) out.add(f.path);
  }
  for (final ext in ['.osm.pbf', '.pbf']) {
    final f = File('$dir$ext');
    if (f.existsSync()) out.add(f.path);
  }
  return out;
}

/// Which path the loader should be handed. Pure, because the decision *is* the
/// bug: a populated folder wins only when it can actually load, otherwise the
/// first sibling source does — an interrupted import must never shadow the file
/// that would fix it.
String graphSourcePath({
  required String dir,
  required bool populated,
  required bool loadable,
  required List<String> siblings,
}) {
  if (populated && loadable) return dir;
  if (siblings.isNotEmpty) return siblings.first;
  return dir;
}

/// Path to pass to the loader: the extracted directory if populated and
/// loadable, else a `.ghz` / `.pbf` file (which the native side converts and
/// deletes), else whatever the Download scan turns up.
Future<String> routingGraphPath() async {
  final dir = await routingGraphDir();
  final d = Directory(dir);
  var populated = false;
  if (d.existsSync()) {
    try {
      populated = d.listSync().isNotEmpty;
    } catch (_) {}
  }
  final siblings = graphSiblingSources(dir);
  if (populated || siblings.isNotEmpty) {
    return graphSourcePath(
      dir: dir,
      populated: populated,
      loadable: populated && graphFolderLoadable(d),
      siblings: siblings,
    );
  }
  // Nothing app-owned: fall back to a loose file in a folder we can read — the
  // app's own external dir first, then the public Downloads, whatever the name.
  final adopted = await adoptExternalGraphSource(dir);
  if (adopted != null) return adopted;
  return File('$dir.ghz').existsSync() ? '$dir.ghz' : dir;
}

/// Public folders a downloaded extract can land in, in the order we look.
const List<String> kPublicDownloadDirs = [
  '/sdcard/Download',
  '/storage/emulated/0/Download',
];

/// Loadable sources inside [dirPath], best first: `.ghz`/`.zip` before a raw
/// PBF (unzipping is minutes faster than importing), then newest first.
///
/// The NAME is not consulted beyond its extension, on purpose. The old code
/// listed exact filenames (`vietnam-latest.osm.pbf`, `graph.ghz`, …), so a file
/// the user actually had — `vietnam-260928.osm.pbf` — matched nothing and sat in
/// Downloads invisible while the app insisted no data had been downloaded.
List<String> graphCandidatesIn(String dirPath) {
  final d = Directory(dirPath);
  if (!d.existsSync()) return const [];
  final found = <(String, int, DateTime)>[];
  try {
    for (final e in d.listSync()) {
      if (e is! File) continue;
      final name = e.path.toLowerCase();
      final isArchive = name.endsWith('.ghz') || name.endsWith('.zip');
      final isPbf = name.endsWith('.osm.pbf') || name.endsWith('.pbf');
      if (!isArchive && !isPbf) continue;
      found.add((e.path, isArchive ? 0 : 1, e.statSync().modified));
    }
  } catch (_) {
    // Scoped storage can deny a raw listing of a public folder; the file picker
    // remains the reliable route on Android 11+.
    return const [];
  }
  found.sort((a, b) {
    final byKind = a.$2.compareTo(b.$2);
    return byKind != 0 ? byKind : b.$3.compareTo(a.$3);
  });
  return [for (final f in found) f.$1];
}

/// Where a sideloaded graph may be dropped so this app can read it, best first.
///
/// `/sdcard/Download` is NOT dependable on Android 11+: a file pushed by `adb`
/// (or written by any other app) belongs to another uid, and the raw path is
/// denied — `File(...).existsSync()` simply answers false, so a perfectly good
/// 247 MB `.ghz` sits there invisible and the app reports "no offline data".
/// Observed on the itel_P663LN: the preload found nothing and failed in 322 ms
/// with the archive present in Downloads.
///
/// `/sdcard/Android/data/<pkg>/files` is owned by the app, readable with no
/// permission, and `adb push` can write it — so it is searched FIRST.
Future<List<String>> graphSearchDirs() async {
  final dirs = <String>[];
  try {
    final ext = await getExternalStorageDirectory();
    if (ext != null) dirs.add(ext.path);
  } catch (_) {
    // Desktop / tests: no external dir, the public list still applies.
  }
  dirs.addAll(kPublicDownloadDirs);
  return dirs;
}

/// Copy a loose graph source from any searchable folder into app storage (a copy
/// the app owns is always readable) and return it.
Future<String?> adoptExternalGraphSource(String dir) async {
  for (final searchDir in await graphSearchDirs()) {
    for (final p in graphCandidatesIn(searchDir)) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final lower = p.toLowerCase();
      final isArchive = lower.endsWith('.ghz') || lower.endsWith('.zip');
      // A file still being written (adb push, an in-flight download) must not be
      // copied: the copy would be truncated, and deleting the source afterwards
      // would destroy the only good bytes. Skip it and let the next start win.
      if (!await _sizeStable(f)) {
        debugPrint('ROUTER: $p is still being written — leaving it alone');
        continue;
      }
      if (isArchive && !zipComplete(f)) {
        debugPrint('ROUTER: $p is an incomplete archive — leaving it alone');
        continue;
      }
      try {
        final ext = lower.endsWith('.osm.pbf')
            ? '.osm.pbf'
            : p.substring(p.lastIndexOf('.'));
        final target = File('$dir$ext');
        if (!target.existsSync() || target.lengthSync() != f.lengthSync()) {
          target.parent.createSync(recursive: true);
          f.copySync(target.path);
        }
        // Verify before reclaiming: same length, and a complete archive.
        final copied =
            target.existsSync() && target.lengthSync() == f.lengthSync();
        final usable = !isArchive || zipComplete(target);
        if (!copied || !usable) {
          debugPrint('ROUTER: adoption of $p did not verify; keeping the source');
          return f.path;
        }
        try {
          f.deleteSync();
        } catch (_) {}
        debugPrint('ROUTER: adopted graph source $p');
        return target.path;
      } catch (e) {
        debugPrint('ROUTER: could not adopt $p: $e');
        return f.path;
      }
    }
  }
  return null;
}

/// True when [f] has stopped growing (two samples ~700 ms apart agree), so a
/// half-written file is never copied.
Future<bool> _sizeStable(File f) async {
  try {
    final a = f.lengthSync();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final b = f.lengthSync();
    return a == b && b > 0;
  } catch (_) {
    return false;
  }
}

/// Where the in-app builder writes the archive: next to the graph folder, so
/// [routingGraphPath] finds it again after a folder wipe or a reinstall.
Future<String> graphArchivePath() async => '${await routingGraphDir()}.ghz';

/// Build a portable `.ghz` from the graph folder currently on the phone.
///
/// The point is to pay the costly part once. Importing the country extract
/// (`tools/data/vietnam-latest.osm.pbf`, 311 MB) needs minutes of CPU and GBs of
/// RAM, and it is what a phone the user hands the PBF to would otherwise do
/// again from scratch; an archive only has to be unzipped. It also makes the
/// finished graph portable — pull it to a PC with `adb pull`, or export it to
/// Downloads and share it.
///
/// Returns null when there is no graph folder to archive yet (import a PBF
/// first); throws only on real native failures.
Future<GraphArchiveResult?> buildGraphArchive({
  void Function(int done, int total)? onProgress,
}) async {
  final dir = await routingGraphDir();
  if (!Directory(dir).existsSync()) return null;

  // These functions are top level (like [downloadGraph]), so the progress sink
  // lives on the singleton; same library, so the private members are reachable.
  final router = OfflineRouter.instance;
  router._installProgressHandler();
  router._archiveProgress = onProgress;
  try {
    final out = await graphArchivePath();
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'buildArchive',
      {'dir': dir, 'out': out},
    );
    if (res == null) return null;
    return GraphArchiveResult(
      path: (res['path'] as String?) ?? out,
      bytes: (res['bytes'] as num?)?.toInt() ?? 0,
      sourceBytes: (res['sourceBytes'] as num?)?.toInt() ?? 0,
    );
  } on PlatformException catch (e) {
    throw StateError(e.message ?? 'Không tạo được tệp .ghz');
  } finally {
    router._archiveProgress = null;
  }
}

/// Copy the built archive into shared storage (Downloads) so it survives an
/// uninstall, is visible to a file manager, and can be pulled with `adb pull`.
///
/// API 29+ publishes it through MediaStore and needs no permission; Android 8–9
/// throws [GraphExportNeedsPermission] so the caller can request it and retry.
Future<String> exportGraphArchive([String? srcPath]) async {
  final src = srcPath ?? await graphArchivePath();
  if (!File(src).existsSync()) {
    throw StateError('Chưa có tệp .ghz để xuất.');
  }
  try {
    final where = await _channel.invokeMethod<String>('exportArchive', {'src': src});
    return where ?? '';
  } on PlatformException catch (e) {
    if (e.code == 'need_permission') throw GraphExportNeedsPermission();
    throw StateError(e.message ?? 'Không xuất được tệp .ghz');
  }
}

/// Load whichever graph source the phone actually has, healing debris first.
///
/// Serialised: the boot preload and the navigation page's preload can fire
/// together, and two concurrent attempts race on the same files — the first
/// extracts an archive and deletes it, the second then fails with
/// "Không tìm thấy dữ liệu: …routing_graph.ghz" (observed on the itel_P663LN).
/// Concurrent callers join the running attempt instead.
Future<bool> loadBestGraph({bool heal = true}) {
  final running = _bestLoadInFlight;
  if (running != null) {
    debugPrint('ROUTER: graph load already in flight — joining it');
    return running;
  }
  final attempt = _loadBestGraph(heal: heal)
      .whenComplete(() => _bestLoadInFlight = null);
  _bestLoadInFlight = attempt;
  return attempt;
}

Future<bool>? _bestLoadInFlight;

Future<bool> _loadBestGraph({required bool heal}) async {
  final dir = await routingGraphDir();
  if (heal) {
    // Debris from an interrupted write cannot be opened by anything: a folder
    // with no GH marker, or an archive with no zip end record. Clear both, or
    // the app keeps choosing them and offline routing stays dead.
    if (await graphFolderCorrupt(dir)) {
      debugPrint(
        'ROUTER: removing interrupted graph folder (no GH marker): $dir',
      );
      try {
        Directory(dir).deleteSync(recursive: true);
      } catch (e) {
        debugPrint('ROUTER: could not remove $dir: $e');
      }
    }
    dropIncompleteArchives(dir);
  }
  final path = await routingGraphPath();
  final exists = File(path).existsSync() || Directory(path).existsSync();
  if (!exists) return false;
  return OfflineRouter.instance.load(path);
}

/// Whether a graph the loader can use is installed.
///
/// A populated folder counts only when it carries the GH marker; otherwise it is
/// debris, and reporting it as present is what let the Offline screen announce
/// "Bộ dữ liệu đã có (249.6 MB)" while every single load threw.
Future<bool> routingGraphPresent() async {
  final dir = await routingGraphDir();
  final d = Directory(dir);
  var populated = false;
  try {
    populated = d.existsSync() && d.listSync().isNotEmpty;
  } catch (_) {}
  if (populated && graphFolderLoadable(d)) return true;
  if (graphSiblingSources(dir).isNotEmpty) return true;
  // Same extension-only rule as the loader: the name is whatever the user's
  // browser gave the file.
  for (final dirPath in await graphSearchDirs()) {
    if (graphCandidatesIn(dirPath).isNotEmpty) return true;
  }
  return false;
}

/// Built-in source for the offline routing graph: the Geofabrik Việt Nam OSM
/// extract. It is an `.osm.pbf`, converted to a GraphHopper graph on the phone
/// by [downloadGraph]; no separately hosted `.ghz` is required.
///
/// 329 MB, verified live (application/octet-stream, `OSMHeader` magic). It is
/// the whole country in one file, which on a low-end phone means a 3-minute
/// import that Android can kill halfway — see the region presets for the faster
/// route, and [graphFolderCorrupt] for what a killed import leaves behind.
const String graphDefaultUrl =
    'https://download.geofabrik.de/asia/vietnam-latest.osm.pbf';

/// Preset region for quick offline routing graph download.
class GraphRegionPreset {
  final String id;
  final String name;
  final String description;
  final String url;
  const GraphRegionPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.url,
  });
}

/// Popular region extracts available for direct download.
///
/// Each URL is verified live, byte-level: HEAD gives
/// `application/octet-stream`/`application/x-pbf` and the first bytes carry the
/// OSM PBF magic. That check matters — a status code alone is not evidence.
/// Geofabrik answers its 404 page with `HTTP 200 text/html` **and** honours
/// range requests, so three presets shipped here 404'd for as long as nobody
/// looked at the bytes.
///
/// Only two Vietnamese sources exist: the country extract, and BBBike's Saigon
/// extract (their index holds no Hà Nội / Đà Nẵng equivalent — a preset pointing
/// there is a dead button, which is why those two are gone rather than repaired).
const List<GraphRegionPreset> kGraphRegionPresets = [
  GraphRegionPreset(
    id: 'saigon',
    name: 'TP. Hồ Chí Minh',
    description: '~14,5 MB PBF (BBBike), xử lý nhanh (~1 phút)',
    url: 'https://download.bbbike.org/osm/bbbike/Saigon/Saigon.osm.pbf',
  ),
  GraphRegionPreset(
    id: 'vietnam',
    name: 'Toàn Việt Nam',
    description: '~314 MB PBF (Geofabrik), toàn quốc — nạp lâu trên máy yếu',
    url: 'https://download.geofabrik.de/asia/vietnam-latest.osm.pbf',
  ),
];

/// The URL [downloadGraph] actually fetches: [customUrl] when given, else the
/// build-time `GRAPH_URL` (with `/graph.ghz` appended unless it already names
/// an archive), else the built-in [graphDefaultUrl].
///
/// Shared with the in-app link list (`offline_links.dart`) so the Offline
/// screen can show the same URL the download would use.
String resolveGraphUrl([String? customUrl]) {
  if (customUrl != null && customUrl.isNotEmpty) return customUrl;
  if (graphDownloadBaseUrl.isEmpty) return graphDefaultUrl;
  if (graphDownloadBaseUrl.endsWith('.ghz') ||
      graphDownloadBaseUrl.endsWith('.pbf')) {
    return graphDownloadBaseUrl;
  }
  return '$graphDownloadBaseUrl/graph.ghz';
}

/// Which half of a graph install is running.
///
/// The two halves are very different to sit through: the download is minutes over
/// the network WITH a percentage, the conversion is minutes of CPU with none. The
/// screen needs to say which one it is in, or a bar sitting at 100% reads as a
/// hung app while the phone is actually building the graph.
enum GraphPhase { downloading, processing }

/// Install the offline routing graph: **download it, then convert it on the
/// phone**.
///
/// ONE region on purpose — Việt Nam. The default source is the Geofabrik Việt Nam
/// extract ([graphDefaultUrl]), i.e. the whole country in one `.osm.pbf`; a
/// per-province or per-tile scheme would need a different converter and a
/// different storage layout, and the phone has to hold the extract AND the built
/// graph at once. `--dart-define=GRAPH_URL` (or a URL typed on the Offline
/// screen) replaces it with your own `.ghz`/`.pbf`, still for this one region.
///
/// ⛔ On a failed conversion the downloaded source is DELETED. Leaving it would
/// make [routingGraphPresent] answer "installed" for the rest of time (it reads
/// the existence of `routing_graph.osm.pbf` as a graph), so the app would claim
/// offline routing it does not have and repeat the same doomed conversion at
/// every start.
Future<bool> downloadGraph({
  void Function(int done, int total)? onProgress,
  void Function(GraphPhase phase)? onPhase,
  String? customUrl,
}) async {
  // resolveGraphUrl owns the precedence: a typed/pasted URL, else GRAPH_URL,
  // else the built-in Việt Nam extract.
  final urlStr = resolveGraphUrl(customUrl);
  final dir = await routingGraphDir();
  final isPbf = urlStr.contains('.pbf');
  final target = isPbf ? '$dir.osm.pbf' : '$dir.ghz';

  onPhase?.call(GraphPhase.downloading);
  final ok = await downloadToFile(urlStr, target, onProgress ?? (_, _) {});
  if (!ok) {
    throw StateError('Không tải được bộ dữ liệu GraphHopper ($urlStr).');
  }

  // Convert (`.pbf` → build a graph) or extract (`.ghz`) on the phone. This runs
  // on the native executor, so minutes are normal for the country extract; the
  // loader deletes the download itself once the graph is built.
  onPhase?.call(GraphPhase.processing);
  final loaded = await OfflineRouter.instance.load(target);
  if (!loaded) {
    _deleteQuietly(target);
    if (isPbf) {
      // The converter deletes the graph folder BEFORE importing, so after a
      // failed import what is left is debris — and a non-empty folder also reads
      // as "installed" to [routingGraphPresent].
      _deleteQuietly(dir, recursive: true);
    }
  }
  return loaded;
}

/// Longest gap between two chunks before a transfer counts as dead.
///
/// The 30 s timeout below covers the response HEADERS only; the body had none at
/// all, so a connection that went quiet mid-file left the download spinning for
/// ever, with the button stuck and no way back except killing the app.
const Duration _downloadStall = Duration(seconds: 45);

/// Download [url] to [target]; true only when the WHOLE file arrived.
///
/// ⚠ ATOMIC: bytes go to `<target>.part` and are renamed into place only after the
/// transfer completes, so a dropped connection can never leave a partial file
/// under the real name. That is the difference between "the download failed, try
/// again" and "the app believes it has a 4 GB Việt Nam extract, but what it has
/// is the first 60% of one". `downloadNavMap` already worked this way. ⛔ This one
/// mattered because [routingGraphPresent] trusts the FILENAME.
Future<bool> downloadToFile(
  String url,
  String target,
  void Function(int done, int total) onProgress,
) async {
  final part = File('$target.part');
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers['User-Agent'] =
        'navbridge/1.0 (BLE portable navigation; graph)';
    final streamed = await client
        .send(req)
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      debugPrint('DL: HTTP ${streamed.statusCode} for $url');
      return false;
    }
    // A 200 is not proof of a file. Geofabrik answers its 404 page with
    // `HTTP 200 text/html` and even honours range requests, so a dead link looks
    // healthy to a status check and only fails later as an unreadable graph. If
    // the server says HTML, the link is gone — say so.
    final ctype = streamed.headers['content-type']?.toLowerCase() ?? '';
    if (ctype.contains('text/html')) {
      debugPrint('DL: $url returned HTML, not map data (link moved or expired)');
      return false;
    }
    final total = streamed.contentLength ?? 0;
    part.parent.createSync(recursive: true);
    if (part.existsSync()) part.deleteSync();
    final sink = part.openWrite();
    var done = 0;
    var complete = false;
    try {
      // `.timeout` on the STREAM, not on the send: it fires per gap between
      // chunks, so a transfer that dies mid-file fails instead of hanging.
      await for (final chunk in streamed.stream.timeout(_downloadStall)) {
        sink.add(chunk);
        done += chunk.length;
        onProgress(done, total);
      }
      await sink.flush();
      complete = true;
    } finally {
      // Closed on EVERY path. The old version returned from the catch with the
      // handle still open and its buffered tail never flushed.
      await sink.close();
    }
    if (!complete || done == 0) return false;
    if (total > 0 && done != total) {
      // A proxy or a dropped connection that closes early looks exactly like a
      // clean end of stream, so compare against the declared length.
      debugPrint('DL: short read $done/$total for $url');
      return false;
    }
    // A 200 carrying an HTML error page or a captive-portal login is not an
    // extract: a `.pbf` is a protobuf blob and a `.ghz` is a zip, so neither
    // begins with '<'.
    final raf = part.openSync();
    final magic = raf.readSync(16);
    raf.closeSync();
    if (magic.isNotEmpty && magic[0] == 0x3C) {
      debugPrint('DL: got a text page, not a graph archive: $url');
      return false;
    }
    final out = File(target);
    if (out.existsSync()) out.deleteSync();
    part.renameSync(target);
    return true;
  } catch (e) {
    debugPrint('DL: failed $url: $e');
    return false;
  } finally {
    // After a successful rename `part` is already gone, so this only ever removes
    // a FAILED transfer's leftovers.
    _deleteQuietly(part.path);
    client.close();
  }
}

/// Delete [path] (file, or directory with [recursive]) and swallow failures.
void _deleteQuietly(String path, {bool recursive = false}) {
  try {
    final f = File(path);
    if (f.existsSync()) {
      f.deleteSync();
      return;
    }
    if (recursive) {
      final d = Directory(path);
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  } catch (_) {}
}

/// Best route source: on-device GraphHopper when loaded, OSRM otherwise.
/// In forced-offline mode only the on-device graph is used (never OSRM).
/// Snap a GPS trace to the road with OSRM's match API — but ONLY when online
/// (the on-device graph has no matching). Returns the snapped point or null.
Future<LatLng?> fetchAnyMatch(List<LatLng> trace) async {
  if (forceOffline) return null;
  return matchGpsTrace(trace);
}

/// Bearing (deg, 0=N) from [a] to [b] — used by the scenic curvature score.
double _bearing(LatLng a, LatLng b) {
  final dLon = (b.longitude - a.longitude) * 0.017453292519943295;
  final lat1 = a.latitude * 0.017453292519943295;
  final lat2 = b.latitude * 0.017453292519943295;
  final y = math.sin(dLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return (math.atan2(y, x) * 57.29577951308232 + 360) % 360;
}

/// Scenic score of a route = total absolute heading change (degrees) along
/// the polyline. Winding routes (hills / coast / old town) score higher — the
/// "đẹp cảnh" preference picks the curviest of the alternatives.
double _routeCurvature(OsrmRoute r) {
  final g = r.geometry;
  if (g.length < 3) return 0;
  var sum = 0.0;
  for (var i = 1; i < g.length - 1; i++) {
    var d = (_bearing(g[i - 1], g[i]) - _bearing(g[i], g[i + 1])).abs() % 360;
    if (d > 180) d = 360 - d;
    sum += d;
  }
  return sum;
}

/// Re-order [routes] so the one matching [pref] is first. "Nhanh nhất" keeps
/// the backend's duration-optimised order. Best-effort: only meaningful when
/// the source returned >1 alternatives (the on-device car graph returns one
/// fastest route → unchanged).
List<OsrmRoute> rankByPreference(List<OsrmRoute> routes, RoutePreference pref) {
  if (routes.length < 2 || pref == RoutePreference.fastest) return routes;
  final ranked = [...routes];
  switch (pref) {
    case RoutePreference.shortest:
      ranked.sort((a, b) => a.distance.compareTo(b.distance));
    case RoutePreference.mainRoads:
      // Main roads → fewer, longer legs (motorway/trunk/primary): highest
      // average step length wins. Heuristic over the alternatives we have.
      double avg(OsrmRoute r) =>
          r.distance / (r.steps.length > 1 ? r.steps.length : 1);
      ranked.sort((a, b) => avg(b).compareTo(avg(a)));
    case RoutePreference.scenic:
      ranked.sort((a, b) => _routeCurvature(b).compareTo(_routeCurvature(a)));
    case RoutePreference.fastest:
      break;
  }
  return ranked;
}

/// Throws when no source is available (fully offline without a graph).
///
/// [profile] selects the road type (car / motorbike / bicycle / walking).
/// The on-device graph carries a car profile only: car routes use it, and a
/// motorbike route is computed on those same car roads (the archive holds no
/// motorcycle encodings). Bicycle and walking always route online (OSRM) so
/// their path matches the mode of transport.
/// With the Vietmap data source active, car + motorbike route on Vietmap
/// (fast, VN-optimized, live congestion); bicycle/walking stay on OSRM.
Future<OsrmRoute> fetchAnyRoute(
  List<LatLng> points, {
  RouteProfile profile = RouteProfile.car,
  bool avoidHighway = false,
  bool avoidFerry = false,
  RoutePreference preference = RoutePreference.fastest,
  Duration? onlineTimeout,
  double? startHeading,
}) async {
  final routes = await fetchAnyRoutes(
    points,
    profile: profile,
    avoidHighway: avoidHighway,
    avoidFerry: avoidFerry,
    preference: preference,
    onlineTimeout: onlineTimeout,
    startHeading: startHeading,
  );
  return routes.first;
}

/// Like [fetchAnyRoute] but returns up to [maxAlternatives] route options
/// (best first) when the active source can produce alternatives (Google /
/// Vietmap / OSRM `alternatives=`); the on-device car graph returns one.
///
/// Walks [resolveRouteChain] — the single source of the provider ORDER — and
/// falls through to the next entry whenever a provider fails or returns
/// nothing. Every fall-through is announced to the driver
/// ([noteRouteFallback]) instead of only hitting the log, and the flags a
/// provider CANNOT honour are documented in `route_providers.dart` rather than
/// being silently dropped here.
///
/// [avoidHighway] / [avoidFerry] are forwarded to every provider that supports
/// them: Google (legacy `avoid=` / v2 `routeModifiers`), the on-device graph
/// (`avoidMotorway`) and OSRM (`exclude=motorway,ferry`, except on the
/// `motorcycle` profile which already bans motorways). Vietmap route v4 has no
/// exclusion parameter, so they are dropped there.
///
/// [onlineTimeout] caps how long an ONLINE attempt (Google / Vietmap) may
/// take before falling through to the on-device graph / OSRM. Live off-route
/// reroutes pass a short budget so a dead zone (tunnel / rural) can't freeze
/// turn-by-turn guidance for 30–60 s waiting on a network that is gone.
/// [startHeading] = departure vehicle bearing (degrees) to guide reroutes along
/// the current direction of travel.
Future<List<OsrmRoute>> fetchAnyRoutes(
  List<LatLng> points, {
  RouteProfile profile = RouteProfile.car,
  int maxAlternatives = 3,
  bool avoidHighway = false,
  bool avoidFerry = false,
  RoutePreference preference = RoutePreference.fastest,
  Duration? onlineTimeout,
  double? startHeading,
}) async {
  final chain = resolveRouteChain(profile);
  Object? lastError;

  for (var i = 0; i < chain.length; i++) {
    final provider = chain[i];
    final next = i + 1 < chain.length ? chain[i + 1] : null;
    try {
      final routes = await _routeVia(
        provider,
        points,
        profile: profile,
        maxAlternatives: maxAlternatives,
        avoidHighway: avoidHighway,
        avoidFerry: avoidFerry,
        onlineTimeout: onlineTimeout,
        startHeading: startHeading,
      );
      if (routes.isNotEmpty) return rankByPreference(routes, preference);
      // Nothing to offer (e.g. the on-device graph has no path) — that is a
      // fall-through, not an error, so don't tell the driver it "failed".
      debugPrint('ROUTER: ${provider.label} returned no route — next');
    } catch (e) {
      lastError = e;
      debugPrint('ROUTER: ${provider.label} failed: $e — next');
      noteRouteFallback(provider: provider.label, next: next?.label, error: e);
    }
  }

  // Nothing left. Prefer the REAL error from the last attempt that threw — a
  // dead network must not be reported as "no offline data" — otherwise explain
  // that no source can serve this profile at all.
  if (lastError != null) throw lastError;
  throw StateError(
    profile == RouteProfile.car || profile == RouteProfile.motorbike
        ? 'Ngoại tuyến: chưa tải bộ dữ liệu chỉ đường'
        : 'Ngoại tuyến: bộ dữ liệu chỉ hỗ trợ ô tô và xe máy',
  );
}

/// Attempt ONE provider from the chain. Throws on failure; returns [] when the
/// provider answered but has no route. Keeping each provider's request in one
/// place makes the promise in `route_providers.dart` auditable — if this drops
/// [avoidHighway], [RouteProviderX.canAvoidHighway] must say so.
Future<List<OsrmRoute>> _routeVia(
  RouteProvider provider,
  List<LatLng> points, {
  required RouteProfile profile,
  required int maxAlternatives,
  required bool avoidHighway,
  required bool avoidFerry,
  Duration? onlineTimeout,
  double? startHeading,
}) async {
  switch (provider) {
    case RouteProvider.google:
      // Motorbike must use Routes API v2 `TWO_WHEELER` (Legacy has no such
      // mode); it honours routeModifiers.avoidHighways/avoidFerries.
      final google = profile == RouteProfile.motorbike
          ? fetchGoogleTwoWheelerRoutes(
              points,
              maxAlternatives: maxAlternatives,
              avoidHighway: avoidHighway,
              avoidFerry: avoidFerry,
            )
          : fetchGoogleRoutes(
              points,
              maxAlternatives: maxAlternatives,
              profile: profile,
              avoidHighway: avoidHighway,
              avoidFerry: avoidFerry,
            );
      return onlineTimeout == null
          ? await google
          : await google.timeout(onlineTimeout);
    case RouteProvider.vietmap:
      // No exclusion parameter in route v4 — avoidHighway/avoidFerry stop here.
      final vietmap = fetchVietmapRoutes(
        points,
        vehicle: profile == RouteProfile.motorbike ? 'motorcycle' : 'car',
        maxAlternatives: maxAlternatives,
      );
      return onlineTimeout == null
          ? await vietmap
          : await vietmap.timeout(onlineTimeout);
    case RouteProvider.graphhopper:
      // Wait for the on-device graph if it's still loading at startup (it can
      // take ~60 s on low-end phones), so offline routing doesn't fail early.
      await OfflineRouter.instance.ready;
      if (!OfflineRouter.instance.isLoaded) return const [];
      return OfflineRouter.instance.route(
        points,
        maxAlternatives: maxAlternatives,
        avoidMotorway: avoidHighway,
        avoidFerry: avoidFerry,
        startHeading: startHeading,
      );
    case RouteProvider.osrm:
      return fetchOsrmRoutes(
        points,
        profile: profile.osrm,
        exclude: osrmExclude(
          // The OSRM `motorcycle` profile already keeps two-wheelers off
          // motorways; `exclude=motorway` is unsupported on that profile.
          avoidHighway: avoidHighway && profile != RouteProfile.motorbike,
          avoidFerry: avoidFerry,
        ),
        maxAlternatives: maxAlternatives,
        timeout: onlineTimeout,
        startBearing: startHeading != null ? (startHeading, 45.0) : null,
      );
  }
}
