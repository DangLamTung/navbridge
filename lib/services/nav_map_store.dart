/// Storage + download of the offline vector navigation map (a single PMTiles
/// file) that MapLibre reads from app storage (`<support>/nav_map/`).
///
/// The map can be bundled with the app (assets) OR downloaded on demand to
/// keep the APK small. The on-disk file always wins: a downloaded map replaces
/// the bundled default. Downloading is disabled until `navMapDownloadBaseUrl`
/// is set at build time (`--dart-define=NAVMAP_URL=http://<host>/`).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'vietmap_config.dart' show navMapDownloadBaseUrl;

/// Filename of the offline vector map (matches `assets/offline_map/manifest.json`).
const String navMapName = 'saigon_z16.pmtiles';

/// Marker file written after a successful download so the UI can tell a
/// user-downloaded map apart from a bundled default copy.
const String _downloadedMarker = '.downloaded';

Future<String> navMapDir() async =>
    '${(await getApplicationSupportDirectory()).path}/nav_map';

/// Path of the nav-map PMTiles on disk (or null when not present).
Future<String?> navMapFilePath() async {
  final f = File('${await navMapDir()}/$navMapName');
  return f.existsSync() ? f.path : null;
}

/// True when the user downloaded the nav map (a `.downloaded` marker exists).
Future<bool> navMapDownloaded() async =>
    File('${await navMapDir()}/$_downloadedMarker').existsSync();

Future<int> navMapBytes() async {
  final f = File('${await navMapDir()}/$navMapName');
  return f.existsSync() ? f.lengthSync() : 0;
}

/// Download the nav-map PMTiles from `$navMapDownloadBaseUrl/$navMapName` into
/// app storage. Throws a clear error when no base URL is configured. Reports
/// progress via [onProgress] (done bytes, total bytes).
Future<void> downloadNavMap(
  void Function(int done, int total)? onProgress,
) async {
  final base = navMapDownloadBaseUrl;
  if (base.isEmpty) {
    throw StateError(
      'Chưa cấu hình URL tải bản đồ dẫn đường (dùng --dart-define=NAVMAP_URL).',
    );
  }
  final url = Uri.parse('$base/$navMapName');
  final client = http.Client();
  try {
    final req = http.Request('GET', url);
    req.headers['User-Agent'] = 'NavBridge/1.0 (offline nav map download)';
    final resp = await client.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError('Tải bản đồ thất bại: HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength ?? 0;
    final dir = Directory(await navMapDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('${dir.path}/$navMapName.part');
    final out = File('${dir.path}/$navMapName');
    final sink = tmp.openWrite();
    var done = 0;
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } finally {
      await sink.close();
    }
    // Only replace the live file after a complete download.
    if (out.existsSync()) out.deleteSync();
    await tmp.rename(out.path);
    await File(
      '${dir.path}/$_downloadedMarker',
    ).writeAsString(DateTime.now().toIso8601String());
    debugPrint('NAVMAP: downloaded $navMapName ($done bytes)');
  } finally {
    client.close();
  }
}

/// Remove a user-downloaded nav map (and its marker). The bundled default
/// copy — if the app still bundles one — is copied again on next use.
Future<void> deleteNavMap() async {
  final dir = Directory(await navMapDir());
  for (final name in [navMapName, _downloadedMarker]) {
    final f = File('${dir.path}/$name');
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}
