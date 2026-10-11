/// Auto-updates the offline point data (traffic cameras + road signs) from a
/// remote server, so the app can refresh these DBs without a new APK.
///
/// Server contract (empty [dataUpdateBaseUrl] = feature disabled):
///   `$DATA_URL/version.json`          → `{"cameras":"<v>","signs":"<v>"}`
///                                      (optional — skip HTTP when unchanged)
///   `$DATA_URL/vietnam_cameras.json`  → same schema as assets/offline_map/
///   `$DATA_URL/vietnam_signs.json`    → same schema as assets/offline_map/
///
/// The downloaded files are written to `<support>/offline_data/`. The loaders
/// (offline_cameras.dart / offline_road_signs.dart) read that folder in
/// preference to the bundled asset, so a newer server copy overrides the APK's
/// bundled data. After a successful download the in-memory loaders are reset
/// ([reloadOfflineCameras], [reloadOfflineRoadSigns]) so the next navigation
/// uses the fresh data.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'offline_cameras.dart' show reloadOfflineCameras;
import 'offline_loader.dart' show offlineDataDir;
import 'offline_poi.dart' show reloadOfflinePois;
import 'offline_road_signs.dart' show reloadOfflineRoadSigns;
import 'offline_speed_limits.dart' show reloadOfflineSpeedLimits;
import 'offline_tiles.dart' show resetOverviewTilesExtraction;
import 'osm_api.dart' show resetOfflinePlaces;
import 'vietmap_config.dart' show effectiveDataUpdateUrl;

/// Every pack the auto-updater syncs, as (version.json key, file name).
///
/// ONE list, driven by the loop in `autoUpdate`, so a pack can never be
/// versioned by the server and yet never fetched by the app. That is exactly
/// what had happened: the posted-limit files were published and versioned for
/// months while nothing consumed them, and the segment layer — the app's
/// primary posted-limit authority — was excluded as "too large", so a
/// limit-data fix could not reach a device without a new APK.
const List<(String, String)> kUpdatePacks = [
  ('cameras', 'vietnam_cameras.json'),
  ('signs', 'vietnam_signs.json'),
  ('speed_limits', 'waze_speed_limits.json'),
  ('vietmap_limits', 'vietmap_speed_limits.json'),
  ('pois', 'vietnam_pois.json'),
  ('places', 'vietnam_places.json'),
  ('nav_style', 'nav_style.json'),
  ('overview_tiles', 'overview_tiles.tar.gz'),
  // ~14 MB gzipped (26 MB plain). Full over-the-air coverage is worth the
  // larger sync: the whole point is that a limit-data fix reaches the device
  // without a new APK.
  ('segments', 'waze_segments.bin'),
];

/// Vietnamese names for the [kUpdatePacks] keys, shown on the offline screen.
/// Kept beside the pack list so a new pack cannot be added without a label.
const Map<String, String> kUpdatePackLabels = {
  'cameras': 'camera giao thông',
  'signs': 'biển báo',
  'speed_limits': 'giới hạn tốc độ Waze',
  'vietmap_limits': 'giới hạn tốc độ Vietmap',
  'pois': 'địa điểm',
  'places': 'tên đường & địa danh',
  'nav_style': 'giao diện bản đồ',
  'overview_tiles': 'ô bản đồ nền',
  'segments': 'tốc độ theo tuyến đường',
};

/// True when [bytes] are a valid pack for [name]: gzip magic for the tile
/// archive, WZSG magic for the segment layer, otherwise valid JSON of an
/// accepted shape (`vietnam_places.json` is a top-level ARRAY, the rest are
/// objects).
///
/// A 200 carrying an HTML error page must never overwrite good local data — and
/// a binary pack must never be rejected merely for not being JSON. Pure, so the
/// accept/reject decision is pinned by a test.
bool saneUpdatePack(String name, List<int> bytes) {
  if (bytes.isEmpty) return false;
  if (name.endsWith('.tar.gz')) {
    return bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  }
  if (name.endsWith('.bin')) {
    // The WZSG segment layer (see tools/signs/build_waze_segments.py).
    return bytes.length > 8 &&
        bytes[0] == 0x57 &&
        bytes[1] == 0x5a && // 'WZ'
        bytes[2] == 0x53 &&
        bytes[3] == 0x47; // 'SG'
  }
  try {
    final j = jsonDecode(utf8.decode(bytes));
    return j is Map || j is List;
  } catch (_) {
    return false;
  }
}

/// Last-known remote versions per file, persisted in
/// `<support>/offline_data/version.json` (the SAME file the server publishes,
/// so the local copy doubles as the "last synced" marker).
class OfflineDataUpdater {
  OfflineDataUpdater._();
  static final OfflineDataUpdater instance = OfflineDataUpdater._();

  static const _ua =
      'NavBridge/1.0 (Android; BLE portable navigation; offline data update)';

  /// True when a remote server is configured ([effectiveDataUpdateUrl] non-empty).
  bool get enabled => effectiveDataUpdateUrl.isNotEmpty;

  bool _busy = false;

  /// Latest versions pulled from the server (for the settings / offline
  /// screen to show whether an update is available).
  Map<String, String>? _remoteVersions;
  Map<String, String> get remoteVersions => _remoteVersions ?? const {};

  /// Result of the most recent check ('' = not run yet).
  String get lastResult => _lastResult;
  String _lastResult = '';

  /// Whether [lastResult] describes a failure, so the UI can colour it. Only
  /// ever true for the two unreachable/failed branches — never for a check that
  /// succeeded and simply found nothing to download.
  bool get lastError => _lastError;
  bool _lastError = false;

  File? _versionFile;

  Future<File> _versionFileFor() async {
    if (_versionFile != null) return _versionFile!;
    final dir = await offlineDataDir();
    return _versionFile = File('${dir.path}/version.json');
  }

  /// Handles two roles: READS the version file (local last-synced marker) and
  /// WRITES it after a successful sync.
  Future<Map<String, String>> _readLocalVersions() async {
    try {
      final f = await _versionFileFor();
      if (!await f.exists()) return const {};
      final j = jsonDecode(await f.readAsString());
      return (j as Map).cast<String, String>();
    } catch (_) {
      return const {};
    }
  }

  Future<void> _writeLocalVersions(Map<String, String> v) async {
    try {
      final f = await _versionFileFor();
      await f.writeAsString(jsonEncode(v), flush: true);
    } catch (_) {}
  }

  /// Check the server for newer data and download it if the version changed
  /// (or no version was stored). Idempotent; only one run at a time. Returns
  /// true when a file was (re)downloaded. Safe to call on the app-start
  /// background thread — never blocks the UI.
  Future<bool> autoUpdate() async {
    if (!enabled || _busy) return false;
    _busy = true;
    try {
      final local = await _readLocalVersions();
      final remote = await _fetchRemoteVersions();
      _remoteVersions = remote;

      // An UNREACHABLE server (no network, 404 — the release was never
      // published, wrong URL) must not be reported as "Dữ liệu đã mới nhất":
      // that told the driver the data was current when it had never been
      // looked at. A server that answers 200 with no versions is a different
      // case — it is reachable and simply has nothing versioned to compare.
      if (!_remoteReachable) {
        _lastResult = 'Không kiểm tra được máy chủ dữ liệu.';
        _lastError = true;
        debugPrint(
          'OFFLINE-DATA: version check failed at $effectiveDataUpdateUrl',
        );
        return false;
      }

      // One list drives the whole sync (see [kUpdatePacks]) so a pack can never
      // be versioned by the server and yet never fetched.
      var changed = false;
      final applied = <String, String>{};
      for (final (key, file) in kUpdatePacks) {
        final remoteV = remote[key];
        if (remoteV == null || remoteV == local[key]) continue;
        if (await _downloadOne(file, remoteV)) {
          applied[key] = remoteV;
          changed = true;
        }
      }
      if (changed) {
        // Record ONLY the versions actually written. Persisting the whole remote
        // map marked a pack whose download FAILED as current, so it was never
        // retried — silent permanent staleness in whatever happened to fail,
        // which is how the posted-limit files went stale in the first place.
        await _writeLocalVersions({...local, ...applied});
        final names = applied.keys.map((k) => kUpdatePackLabels[k] ?? k);
        // Name what changed. "Đã cập nhật dữ liệu ngoại tuyến." told the driver
        // nothing: not how many packs, not which — so a sync that silently
        // fetched one unrelated file looked identical to a full refresh.
        _lastResult = applied.length >= kUpdatePacks.length
            ? 'Đã cập nhật toàn bộ ${kUpdatePacks.length} gói dữ liệu.'
            : 'Đã cập nhật ${applied.length}/${kUpdatePacks.length} gói: '
                  '${names.join(', ')}.';
        _lastError = false;
      } else {
        _lastResult =
            'Đã kiểm tra ${kUpdatePacks.length} gói — tất cả đều mới nhất.';
        _lastError = false;
      }
      // Always report on a SUCCESSFUL check. Without this, "ran and everything
      // was already current" is indistinguishable in logcat from "never ran at
      // all" — the same silent-nothing ambiguity that let a stale pack look
      // current. Only the failure branches spoke before this line existed.
      debugPrint(
        'OFFLINE-DATA: check ok, ${applied.length} of ${kUpdatePacks.length} '
        'packs updated'
        '${applied.isEmpty ? ' (all current)' : ': ${applied.keys.join(', ')}'}',
      );
      return changed;
    } catch (e) {
      debugPrint('OFFLINE-DATA: auto-update failed: $e');
      _lastResult = 'Cập nhật thất bại.';
      _lastError = true;
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Fetch the remote `version.json`. Returns a map — EMPTY when the server
  /// answers 200 but publishes no versions, in which case there is nothing to
  /// version-compare and [autoUpdate] downloads nothing (the bundled assets
  /// stay in use). Check [_remoteReachable] to tell that apart from a request
  /// that never got an answer at all.
  Future<Map<String, String>> _fetchRemoteVersions() async {
    try {
      final url = '$effectiveDataUpdateUrl/version.json';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        _remoteReachable = true;
        final j = jsonDecode(res.body);
        return (j as Map).cast<String, String>();
      }
      debugPrint(
        'OFFLINE-DATA: version.json -> HTTP ${res.statusCode} at $url',
      );
    } catch (e) {
      debugPrint('OFFLINE-DATA: version.json request failed: $e');
    }
    return const {};
  }

  /// True once a `version.json` has been read with HTTP 200. Stays false when
  /// the request never got an answer — see the check in [autoUpdate].
  bool _remoteReachable = false;

  /// Drop the in-memory copy of [name] so the next read uses the fresh file.
  void _reloadFor(String name) {
    if (name == 'vietnam_cameras.json') {
      reloadOfflineCameras();
    } else if (name == 'vietnam_signs.json') {
      reloadOfflineRoadSigns();
    } else if (name == 'waze_speed_limits.json' ||
        name == 'vietmap_speed_limits.json' ||
        name == 'waze_segments.bin') {
      // All three are read by the same limit layer (offline_speed_limits).
      reloadOfflineSpeedLimits();
    } else if (name == 'vietnam_pois.json') {
      reloadOfflinePois();
    } else if (name == 'vietnam_places.json') {
      resetOfflinePlaces();
    } else if (name == 'overview_tiles.tar.gz') {
      resetOverviewTilesExtraction();
    }
  }

  /// Download [name] (e.g. `vietnam_cameras.json`) from the server into
  /// `<support>/offline_data/`. Returns true when the file was written.
  ///
  /// The compressed `<name>.gz` is tried FIRST: these packs are large JSON that
  /// gzip shrinks several-fold, which matters on a phone's data plan. Falls back
  /// to the plain file so an older server keeps serving.
  Future<bool> _downloadOne(String name, String version) async {
    // A pack that is already a .tar.gz has no separate compressed form.
    final suffixes = name.endsWith('.gz') ? const [''] : const ['.gz', ''];
    for (final suffix in suffixes) {
      try {
        final url = '$effectiveDataUpdateUrl/$name$suffix';
        final res = await http
            .get(Uri.parse(url), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 60));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) continue;
        final bytes = suffix == '.gz'
            ? gzip.decode(res.bodyBytes)
            : res.bodyBytes;
        if (!saneUpdatePack(name, bytes)) continue;
        final dir = await offlineDataDir();
        final f = File('${dir.path}/$name');
        // Write atomically: a crash mid-write must never leave a truncated
        // file that the loader would prefer over the bundled asset.
        final part = File('${f.path}.part');
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(f.path);
        // Reset the in-memory loader so the nav uses the fresh data now.
        _reloadFor(name);
        debugPrint(
          'OFFLINE-DATA: $name updated to v$version'
          '${suffix.isEmpty ? '' : ' (gz)'}',
        );
        return true;
      } catch (e) {
        debugPrint('OFFLINE-DATA: download $name$suffix failed: $e');
      }
    }
    return false;
  }
}
