/// Generic cached-async loader used by the offline data services.
///
/// Each service used to repeat the same `_loaded` / `_loading` / `loadXxx()`
/// boilerplate; this hoists it so a service only supplies the actual fetch
/// and the caching + failure-fallback live in one place.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// App-support folder for auto-updated offline point data (cameras / signs).
/// The updater writes here; the loaders read this in preference to the bundled
/// asset so a newer server copy overrides the APK's bundled data.
Future<Directory> offlineDataDir() async {
  final sup = await getApplicationSupportDirectory();
  final d = Directory('${sup.path}/offline_data');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// Path to an auto-updated data file (e.g. `vietnam_cameras.json`), or null if
/// it hasn't been downloaded yet.
Future<File?> offlineDataFile(String name) async {
  final dir = await offlineDataDir();
  final f = File('${dir.path}/$name');
  return f.existsSync() ? f : null;
}

/// Read an offline data file, preferring an auto-updated copy from the server
/// over the one bundled in the APK.
///
/// This is the ONE place that decision is made. It used to be copy-pasted per
/// loader (cameras, signs) and the speed-limit layer had no copy at all, so a
/// posted-limit file downloaded from the update server could never take effect.
/// A missing/unreadable download falls back to the bundled copy instead of
/// failing the load: the app keeps working with the data it shipped with.
Future<String> readOfflineText(String name) async {
  final f = await _downloadedFile(name);
  if (f != null) {
    try {
      return await f.readAsString();
    } catch (_) {
      // Corrupt or half-written download — use the bundled copy.
    }
  }
  return rootBundle.loadString('assets/offline_map/$name');
}

/// Same as [readOfflineText] for binary packs (`waze_segments.bin`).
Future<Uint8List> readOfflineBytes(String name) async {
  final f = await _downloadedFile(name);
  if (f != null) {
    try {
      return await f.readAsBytes();
    } catch (_) {
      // Fall through to the bundled pack.
    }
  }
  final data = await rootBundle.load('assets/offline_map/$name');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// The downloaded copy of [name], or null when there is none — including when
/// there is no app-support directory at all (unit tests, where path_provider
/// has no plugin).
Future<File?> _downloadedFile(String name) async {
  try {
    return await offlineDataFile(name);
  } catch (_) {
    return null;
  }
}

/// Lazily loads a list once and caches it. On failure it caches an empty list
/// and never retries — callers are expected to degrade gracefully (e.g. show
/// the statutory default instead of a real value).
class OfflineListLoader<T> {
  final Future<List<T>> Function() _fetch;

  List<T>? _items;
  Future<List<T>>? _loading;

  OfflineListLoader(this._fetch);

  /// Load the value once (idempotent, cached). Never throws; a failed fetch
  /// yields an empty list.
  Future<List<T>> load() {
    final cached = _items;
    if (cached != null) return Future.value(cached);
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    final fut = _doLoad();
    _loading = fut;
    return fut;
  }

  Future<List<T>> _doLoad() async {
    try {
      _items = await _fetch();
    } catch (_) {
      _items = const [];
    } finally {
      _loading = null;
    }
    return _items!;
  }

  /// Drop the cached value (and any in-flight load) so the next [load()] re-runs
  /// the fetch. Used after the raw data file is replaced by an auto-update, so
  /// the in-memory DB picks up the new records.
  void reload() {
    _items = null;
    _loading = null;
  }
}
