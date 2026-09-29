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
import 'package:flutter/services.dart' show rootBundle;
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

/// Path of the nav-map PMTiles on disk (or null when not present). Checks app
/// storage and external Download directory.
Future<String?> navMapFilePath() async {
  final dir = await navMapDir();
  final f = File('$dir/$navMapName');
  if (f.existsSync()) return f.path;
  if (!kIsWeb) {
    for (final p in [
      '/sdcard/Download/$navMapName',
      '/storage/emulated/0/Download/$navMapName',
    ]) {
      final dl = File(p);
      if (dl.existsSync()) {
        try {
          final d = Directory(dir);
          if (!d.existsSync()) d.createSync(recursive: true);
          dl.copySync(f.path);
          File('$dir/$_downloadedMarker')
              .writeAsStringSync(DateTime.now().toIso8601String());
          try {
            dl.deleteSync();
          } catch (_) {}
          return f.path;
        } catch (_) {
          return dl.path;
        }
      }
    }
  }
  return null;
}

/// True when the user downloaded the nav map (a `.downloaded` marker exists).
Future<bool> navMapDownloaded() async =>
    File('${await navMapDir()}/$_downloadedMarker').existsSync();

Future<int> navMapBytes() async {
  final path = await navMapFilePath();
  if (path == null) return 0;
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

/// Install a locally chosen PMTiles file into the app's offline nav-map store.
Future<bool> installNavMapFile(String sourceFilePath) async {
  final src = File(sourceFilePath);
  if (!src.existsSync()) return false;
  final dir = Directory(await navMapDir());
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final out = File('${dir.path}/$navMapName');
  if (out.existsSync()) out.deleteSync();
  await src.copy(out.path);
  await File('${dir.path}/$_downloadedMarker')
      .writeAsString(DateTime.now().toIso8601String());
  debugPrint('NAVMAP: installed $sourceFilePath -> ${out.path} (${src.lengthSync()} bytes)');
  return true;
}

/// Extract bundled asset saigon_z16.pmtiles to nav_map directory if available.
Future<bool> extractBundledNavMap({
  void Function(int done, int total)? onProgress,
}) async {
  try {
    final data = await rootBundle.load('assets/offline_map/$navMapName');
    final dir = Directory(await navMapDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final out = File('${dir.path}/$navMapName');
    final total = data.lengthInBytes;
    final sink = out.openWrite();
    const chunkSize = 64 * 1024;
    var written = 0;
    while (written < total) {
      final len = (total - written) < chunkSize ? (total - written) : chunkSize;
      final bytes = data.buffer.asUint8List(data.offsetInBytes + written, len);
      sink.add(bytes);
      written += len;
      onProgress?.call(written, total);
    }
    await sink.flush();
    await sink.close();
    await File('${dir.path}/$_downloadedMarker')
        .writeAsString(DateTime.now().toIso8601String());
    debugPrint('NAVMAP: extracted bundled asset ($written bytes)');
    return true;
  } catch (e) {
    debugPrint('NAVMAP: extract bundled asset failed: $e');
    return false;
  }
}

/// Download the nav-map PMTiles from [customUrl] or `$navMapDownloadBaseUrl/$navMapName` into
/// app storage. Reports progress via [onProgress] (done bytes, total bytes).
Future<void> downloadNavMap({
  void Function(int done, int total)? onProgress,
  String? customUrl,
}) async {
  String? urlStr = customUrl?.trim();
  if (urlStr == null || urlStr.isEmpty) {
    if (navMapDownloadBaseUrl.isNotEmpty) {
      urlStr = '$navMapDownloadBaseUrl/$navMapName';
    }
  }
  if (urlStr == null || urlStr.isEmpty) {
    throw StateError(
      'Chưa cấu hình URL tải bản đồ dẫn đường (nhập URL hoặc dùng --dart-define=NAVMAP_URL).',
    );
  }
  final url = Uri.parse(urlStr);
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
