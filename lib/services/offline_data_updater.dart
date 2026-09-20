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
import 'offline_road_signs.dart' show reloadOfflineRoadSigns;
import 'offline_speed_limits.dart' show reloadOfflineSpeedLimits;
import 'vietmap_config.dart' show dataUpdateBaseUrl;

/// Last-known remote versions per file, persisted in
/// `<support>/offline_data/version.json` (the SAME file the server publishes,
/// so the local copy doubles as the "last synced" marker).
class OfflineDataUpdater {
  OfflineDataUpdater._();
  static final OfflineDataUpdater instance = OfflineDataUpdater._();

  static const _ua =
      'NavBridge/1.0 (Android; BLE portable navigation; offline data update)';

  /// True when a remote server is configured ([dataUpdateBaseUrl] non-empty).
  bool get enabled => dataUpdateBaseUrl.isNotEmpty;

  bool _busy = false;

  /// Latest versions pulled from the server (for the settings / offline
  /// screen to show whether an update is available).
  Map<String, String>? _remoteVersions;
  Map<String, String> get remoteVersions => _remoteVersions ?? const {};

  /// Result of the most recent check ('' = up to date / unavailable).
  String get lastResult => _lastResult;
  String _lastResult = '';

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

      var changed = false;
      // 1. Camera data.
      final camV = remote['cameras'];
      if (camV != null && camV != local['cameras']) {
        changed = await _downloadOne('vietnam_cameras.json', camV) || changed;
      }
      // 2. Sign data.
      final signV = remote['signs'];
      if (signV != null && signV != local['signs']) {
        changed = await _downloadOne('vietnam_signs.json', signV) || changed;
      }
      // 3. Posted speed-limit points. The server has always versioned this
      // (`speed_limits` in version.json) and published the file, but nothing
      // consumed it: the offline layer read only the bundled asset, so a data
      // update to posted limits could not reach users without a new APK.
      // `waze_segments.bin` (28 MB) is deliberately NOT auto-downloaded — too
      // large for a background sync; the loader will prefer it if present.
      final speedV = remote['speed_limits'];
      if (speedV != null && speedV != local['speed_limits']) {
        changed =
            await _downloadOne('waze_speed_limits.json', speedV) || changed;
      }
      if (changed) {
        // In-memory loaders were reset inside _downloadOne; also record the
        // synced versions so the next launch doesn't re-download identical data.
        await _writeLocalVersions(remote);
        _lastResult = 'Đã cập nhật dữ liệu ngoại tuyến.';
      } else {
        _lastResult = 'Dữ liệu đã mới nhất.';
      }
      return changed;
    } catch (e) {
      debugPrint('OFFLINE-DATA: auto-update failed: $e');
      _lastResult = 'Cập nhật thất bại.';
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Fetch the remote `version.json`. Returns a map (possibly empty when the
  /// server doesn't publish one — then each file is always (re)downloaded).
  Future<Map<String, String>> _fetchRemoteVersions() async {
    try {
      final url = '$dataUpdateBaseUrl/version.json';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body);
        return (j as Map).cast<String, String>();
      }
    } catch (_) {}
    return const {};
  }

  /// Download [name] (e.g. `vietnam_cameras.json`) from the server into
  /// `<support>/offline_data/`. Returns true when the file was written.
  Future<bool> _downloadOne(String name, String version) async {
    try {
      final url = '$dataUpdateBaseUrl/$name';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return false;
      // Sanity: must be valid JSON with the expected top-level array key — a
      // 200 HTML/error page must never overwrite the good local data.
      final j = jsonDecode(res.body);
      if (j is! Map) return false;
      final dir = await offlineDataDir();
      final f = File('${dir.path}/$name');
      // Write atomically: a crash mid-write must never leave a truncated JSON
      // file that the loader would prefer over the bundled asset.
      final part = File('${f.path}.part');
      await part.writeAsString(res.body, flush: true);
      await part.rename(f.path);
      // Reset the in-memory loader so the nav uses the fresh data.
      if (name == 'vietnam_cameras.json') {
        reloadOfflineCameras();
      } else if (name == 'vietnam_signs.json') {
        reloadOfflineRoadSigns();
      } else if (name == 'waze_speed_limits.json') {
        reloadOfflineSpeedLimits();
      }
      debugPrint('OFFLINE-DATA: $name updated to v$version');
      return true;
    } catch (e) {
      debugPrint('OFFLINE-DATA: download $name failed: $e');
      return false;
    }
  }
}
