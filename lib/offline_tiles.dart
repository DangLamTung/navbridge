/// Offline OSM tile store + region downloader + a custom [TileProvider] that
/// serves tiles from disk and auto-caches every viewed tile.
///
/// Tiles live in `<support>/offline_tiles/{z}/{x}/{y}.png`. Region metadata is
/// kept in `<support>/offline_regions.json` so a region can be deleted later.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

const String _ua = 'navbridge/1.0 (BLE portable navigation; offline tiles)';

/// Base URL for bulk region tile downloads.
///
/// MUST stay empty: bulk/pre-downloading whole regions from
/// tile.openstreetmap.org violates the OSM tile usage policy. To enable
/// region downloads, set this to a self-hosted or licensed tile server that
/// returns `/z/x/y.png` tiles (e.g. 'https://tiles.example.org'). When empty,
/// only tiles actually viewed are cached (compliant) and the downloader is
/// disabled.
const String tileDownloadBaseUrl = '';

/// Average tile size (bytes) per zoom — used for pre-download size estimates.
const Map<int, int> _avgBytes = {
  0: 5000, 1: 5000, 2: 5000, 3: 6000, 4: 6000, 5: 7000, 6: 7000, 7: 8000,
  8: 9000, 9: 10000, 10: 12000, 11: 14000, 12: 16000, 13: 20000, 14: 26000,
  15: 36000, 16: 50000, 17: 70000, 18: 90000, 19: 110000,
};

int _avgTileBytes(int z) => _avgBytes[z] ?? 30000;

// ---- online / offline --------------------------------------------------

/// True when the device has any connectivity.
Future<bool> isOnline() async {
  try {
    final r = await Connectivity().checkConnectivity();
    return r.isNotEmpty && !r.contains(ConnectivityResult.none);
  } catch (_) {
    return true; // assume online when the plugin is unavailable
  }
}

/// Stream of connectivity changes (true = online).
Stream<bool> onlineStream() => Connectivity()
    .onConnectivityChanged
    .map((r) => r.isNotEmpty && !r.contains(ConnectivityResult.none));

// ---- slippy tile math --------------------------------------------------

int lonToTileX(double lon, int z) =>
    ((lon + 180.0) / 360.0 * math.pow(2, z)).floor();

int latToTileY(double lat, int z) {
  final r = lat * math.pi / 180.0;
  return ((1.0 -
              math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) /
          2.0 *
          math.pow(2, z))
      .floor();
}

int _tileCount(LatLngBounds b, int z) {
  final x0 = lonToTileX(b.west, z);
  final x1 = lonToTileX(b.east, z);
  final y0 = latToTileY(b.north, z);
  final y1 = latToTileY(b.south, z);
  return (x1 - x0 + 1) * (y1 - y0 + 1);
}

// ---- store -------------------------------------------------------------

Future<Directory> tileStoreDir() async {
  final sup = await getApplicationSupportDirectory();
  final d = Directory('${sup.path}/offline_tiles');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Future<File> tileFile(int z, int x, int y) async {
  final root = await tileStoreDir();
  return File('${root.path}/$z/$x/$y.png');
}

/// Total size of every stored tile (auto-cache + downloaded regions).
Future<int> tileCacheBytes() async {
  final root = await tileStoreDir();
  var total = 0;
  await for (final f in root.list(recursive: true)) {
    if (f is File && f.path.endsWith('.png')) total += f.lengthSync();
  }
  return total;
}

/// Remove every stored tile (auto-cache + downloaded regions).
Future<void> clearTileCache() async {
  final root = await tileStoreDir();
  try {
    for (final e in root.listSync()) {
      if (e is Directory) {
        e.deleteSync(recursive: true);
      } else if (e is File) {
        e.deleteSync();
      }
    }
  } catch (_) {}
}

// ---- region model ------------------------------------------------------

/// A downloaded (or planned) offline region.
class OfflineRegion {
  final String name;
  final double swLat, swLon, neLat, neLon;
  final int minZoom, maxZoom;
  final DateTime downloadedAt;

  OfflineRegion({
    required this.name,
    required this.swLat,
    required this.swLon,
    required this.neLat,
    required this.neLon,
    required this.minZoom,
    required this.maxZoom,
    required this.downloadedAt,
  });

  LatLngBounds get bounds =>
      LatLngBounds(LatLng(swLat, swLon), LatLng(neLat, neLon));

  int get tileCount {
    var n = 0;
    for (var z = minZoom; z <= maxZoom; z++) {
      n += _tileCount(bounds, z);
    }
    return n;
  }

  int get estimatedBytes {
    var b = 0;
    for (var z = minZoom; z <= maxZoom; z++) {
      b += _tileCount(bounds, z) * _avgTileBytes(z);
    }
    return b;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'swLat': swLat,
        'swLon': swLon,
        'neLat': neLat,
        'neLon': neLon,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
        'downloadedAt': downloadedAt.toIso8601String(),
      };

  factory OfflineRegion.fromJson(Map<String, dynamic> j) => OfflineRegion(
        name: (j['name'] ?? 'region') as String,
        swLat: (j['swLat'] as num).toDouble(),
        swLon: (j['swLon'] as num).toDouble(),
        neLat: (j['neLat'] as num).toDouble(),
        neLon: (j['neLon'] as num).toDouble(),
        minZoom: (j['minZoom'] as num).toInt(),
        maxZoom: (j['maxZoom'] as num).toInt(),
        downloadedAt:
            DateTime.tryParse((j['downloadedAt'] ?? '') as String) ?? DateTime.now(),
      );
}

Future<List<OfflineRegion>> loadRegions() async {
  final sup = await getApplicationSupportDirectory();
  final f = File('${sup.path}/offline_regions.json');
  if (!f.existsSync()) return [];
  try {
    final data = jsonDecode(f.readAsStringSync()) as List;
    return data
        .map((e) => OfflineRegion.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveRegions(List<OfflineRegion> rs) async {
  final sup = await getApplicationSupportDirectory();
  final f = File('${sup.path}/offline_regions.json');
  await f.writeAsString(
      jsonEncode([for (final r in rs) r.toJson()]), flush: true);
}

// ---- downloader --------------------------------------------------------

/// Downloads all tiles of a region with progress + cancel support.
///
/// Only enabled when [tileDownloadBaseUrl] points at a self-hosted / licensed
/// tile server — bulk downloads from tile.openstreetmap.org are not allowed
/// by the OSM tile usage policy. The downloader is single-threaded and
/// rate-limited to ~1 tile/second.
class RegionDownloader {
  final OfflineRegion region;
  int done = 0;
  int get total => region.tileCount;
  bool _cancel = false;
  int failed = 0;
  bool _blocked = false;
  bool get blocked => _blocked;
  bool get disabled => tileDownloadBaseUrl.isEmpty;

  RegionDownloader(this.region);

  void cancel() => _cancel = true;

  Future<void> download(void Function(int done, int total) onProgress) async {
    if (tileDownloadBaseUrl.isEmpty) return; // policy: no bulk OSM download
    done = 0;
    failed = 0;
    _blocked = false;
    final b = region.bounds;
    var lastRequest = DateTime.now();
    const minGap = Duration(milliseconds: 1050); // ~1 tile/s, policy-safe
    for (var z = region.minZoom; z <= region.maxZoom; z++) {
      if (_cancel) return;
      final x0 = lonToTileX(b.west, z);
      final x1 = lonToTileX(b.east, z);
      final y0 = latToTileY(b.north, z);
      final y1 = latToTileY(b.south, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (_cancel) return;
          final f = await tileFile(z, x, y);
          if (f.existsSync()) {
            done++;
            continue;
          }
          // Respect ~1 tile/s.
          final wait = minGap - DateTime.now().difference(lastRequest);
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
          }
          lastRequest = DateTime.now();
          try {
            final res = await http
                .get(Uri.parse('$tileDownloadBaseUrl/$z/$x/$y.png'),
                    headers: {'User-Agent': _ua})
                .timeout(const Duration(seconds: 10));
            if (res.statusCode == 429 || res.statusCode == 403) {
              _blocked = true; // stop before we get IP-banned
              return;
            }
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              f.createSync(recursive: true);
              f.writeAsBytesSync(res.bodyBytes);
            } else {
              failed++;
            }
          } catch (_) {
            failed++;
          }
          done++;
          onProgress(done, total);
        }
      }
    }
  }
}

/// Remove every tile belonging to [r] from the store.
Future<void> deleteRegion(OfflineRegion r) async {
  final root = await tileStoreDir();
  final b = r.bounds;
  for (var z = r.minZoom; z <= r.maxZoom; z++) {
    final x0 = lonToTileX(b.west, z);
    final x1 = lonToTileX(b.east, z);
    final y0 = latToTileY(b.north, z);
    final y1 = latToTileY(b.south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        try {
          final f = File('${root.path}/$z/$x/$y.png');
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }
}

// ---- map tile provider -------------------------------------------------

/// Serves tiles from disk; when missing and online, downloads and caches
/// them; when missing and offline, shows a transparent tile.
class OfflineTileProvider extends TileProvider {
  OfflineTileProvider() : super();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      OfflineTileImage(coordinates, options);
}

class OfflineTileImage extends ImageProvider<OfflineTileImage> {
  final TileCoordinates coordinates;
  final TileLayer options;

  OfflineTileImage(this.coordinates, this.options);

  int get z => coordinates.z;
  int get x => coordinates.x;
  int get y => coordinates.y;

  @override
  Future<OfflineTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<OfflineTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
          OfflineTileImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final file = await tileFile(z, x, y);
    if (file.existsSync()) {
      try {
        return _decode(decode, file.readAsBytesSync());
      } catch (_) {
        // corrupt tile — fall through to re-download
      }
    }
    if (await isOnline()) {
      try {
        final url = (options.urlTemplate ?? '')
            .replaceAll('{z}', '$z')
            .replaceAll('{x}', '$x')
            .replaceAll('{y}', '$y');
        final res = await http
            .get(Uri.parse(url), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          file.createSync(recursive: true);
          file.writeAsBytesSync(res.bodyBytes);
          return _decode(decode, res.bodyBytes);
        }
      } catch (_) {
        // fall through to transparent tile
      }
    }
    return _decode(decode, TileProvider.transparentImage);
  }

  Future<ImageInfo> _decode(ImageDecoderCallback decode, Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image, scale: 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is OfflineTileImage &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);
}
