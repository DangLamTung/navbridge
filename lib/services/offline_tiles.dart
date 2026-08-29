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

/// User-Agent sent with every tile request. The OSM tile policy REQUIRES a
/// distinct, stable User-Agent that names the app (library defaults are
/// blocked).
const String _ua =
    'NavBridge/1.0 (Android; BLE portable navigation; online map display)';

// ---- OSM-compliant tile fetching ---------------------------------------
//
// tile.openstreetmap.org enforces its tile usage policy: max 2 download
// threads and ~1 tile per second. flutter_map normally fires a burst of
// concurrent requests while panning/zooming → 403/429 blocks (and can get
// the IP banned). This coordinator serializes every tile fetch so the app
// stays under the limit, and automatically fails over to other free
// OSM-based tile servers when one blocks us (an IP ban on
// tile.openstreetmap.org does NOT affect other providers).

/// Max concurrent tile HTTP fetches (OSM policy: <= 2 threads).
const int _maxTileConcurrency = 2;

/// Minimum gap between tile requests (OSM policy: ~1 tile/s).
const Duration _minTileGap = Duration(milliseconds: 1000);

/// How long to pause ALL fetches when every server has blocked us.
const Duration _blockBackoff = Duration(minutes: 5);

/// Fallback tile servers PER BASEMAP SOURCE (no API key, attribution
/// required), used when the primary server fails. Each source only fails
/// over to servers with the SAME VISUAL STYLE — so a blocked/rate-limited
/// OSM never silently makes the map look like CARTO or terrain (the old
/// global fallback mixed styles → "the map type keeps changing"). `{s}` is
/// substituted with a/b/c for providers that use subdomains.
const Map<String, List<String>> _fallbackTileTemplatesBySource = {
  // OSM: no regional mirrors (German/French mirrors render different styles
  // and foreign language labels which caused the map style to change when zooming).
  'osm': <String>[],
  // CARTO Voyager: same style, balanced across subdomains.
  'carto': [
    'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    'https://b.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    'https://c.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
  ],
  // OpenTopoMap terrain: no free mirror — degrade to transparent if blocked.
  'topo': <String>[],
  // ESRI satellite: no free mirror — degrade to transparent if blocked.
  'esri': <String>[],
};

DateTime _lastTileRequest = DateTime.fromMillisecondsSinceEpoch(0);
DateTime _tileBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
int _tileInFlight = 0;
final Set<String> _inFlightTiles = {};
final Set<String> _failedTiles = {};
final Set<String> _blockedTileServers = {};
List<String> _serverList = [];
int _serverIndex = 0;

String _tileUrl(String template, int z, int x, int y) {
  var url = template
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');
  // Some providers balance across a/b/c subdomains.
  const subs = ['a', 'b', 'c'];
  url = url.replaceAll('{s}', subs[(x + y) % subs.length]);
  return url;
}

String _tileHost(String template) {
  try {
    final h = Uri.parse(template).host;
    return h.isEmpty ? template : h;
  } catch (_) {
    return template;
  }
}

/// Fetches one tile respecting the OSM tile policy, with automatic failover
/// across the primary + fallback tile servers. Returns null when every
/// server failed — callers fall back to a transparent tile.
Future<http.Response?> _fetchTile(
  int z,
  int x,
  int y,
  String primary,
  String source,
) async {
  final key = '$source/$z/$x/$y';
  if (_tileBlockedUntil.isAfter(DateTime.now())) return null; // all blocked
  if (_failedTiles.contains(key) || _inFlightTiles.contains(key)) return null;

  // (Re)build the server rotation whenever the primary template changes
  // (i.e. the user switched basemap layer) — otherwise a new layer like ESRI
  // would never be requested because its URL is not in the stale list.
  // The fallback list is STYLE-MATCHED to the active source so a blocked
  // primary never swaps the map to a different look (OSM → CARTO/terrain).
  if (_serverList.isEmpty || _serverList.first != primary) {
    _serverList = [
      primary,
      ...(_fallbackTileTemplatesBySource[source] ?? const []),
    ];
    _serverIndex = 0;
  }

  // Every server has blocked us this session → pause, then start fresh.
  if (_blockedTileServers.containsAll(_serverList)) {
    _tileBlockedUntil = DateTime.now().add(_blockBackoff);
    _blockedTileServers.clear();
    _serverIndex = 0;
    debugPrint(
      'TILE: all tile servers blocked — pausing '
      '${_blockBackoff.inMinutes} min',
    );
    return null;
  }

  // Try servers in rotation until one serves this tile.
  var tried = 0;
  while (tried < _serverList.length) {
    // Rotate to the next non-blocked server, BOUNDED to the list length.
    // The rotation must never busy-spin: if every server in the list is
    // blocked (e.g. a concurrent _fetchTile blocked the last free one right
    // after the containsAll guard above), cycling the index forever never
    // exits — the old code hit this and pegged the main thread at 100% CPU
    // ("app isn't responding" ANR) whenever the tile servers blocked the
    // phone (403/429, common on bulk/low-zoom loading).
    var guard = 0;
    while (_blockedTileServers.contains(_serverList[_serverIndex]) &&
        guard < _serverList.length) {
      _serverIndex = (_serverIndex + 1) % _serverList.length;
      guard++;
    }
    final template = _serverList[_serverIndex];
    // Bounded rotation exhausted every server and all are still blocked →
    // pause the session and restart clean (never spin, never crash).
    if (_blockedTileServers.contains(template)) {
      _tileBlockedUntil = DateTime.now().add(_blockBackoff);
      _blockedTileServers.clear();
      _serverIndex = 0;
      debugPrint(
        'TILE: all servers blocked mid-fetch — pausing '
        '${_blockBackoff.inMinutes} min',
      );
      return null;
    }

    // Wait for a concurrency slot.
    while (_tileInFlight >= _maxTileConcurrency) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // Respect the ~1 tile/s minimum spacing.
    final wait = _minTileGap - DateTime.now().difference(_lastTileRequest);
    if (wait > Duration.zero) await Future<void>.delayed(wait);

    _tileInFlight++;
    _inFlightTiles.add(key);
    _lastTileRequest = DateTime.now();
    try {
      final res = await http
          .get(
            Uri.parse(_tileUrl(template, z, x, y)),
            headers: {'User-Agent': _ua},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 403 || res.statusCode == 429) {
        // This provider blocked us — remember it and try the next one.
        _blockedTileServers.add(template);
        debugPrint(
          'TILE: ${_tileHost(template)} blocked '
          '(${res.statusCode}) — switching server',
        );
        _serverIndex = (_serverIndex + 1) % _serverList.length;
        tried++;
        continue;
      }
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        _failedTiles.add(key); // don't re-request the same missing tile
        return null;
      }
      // Some tile servers serve their "access blocked" placeholder with
      // HTTP 200 (not 403) when the client's IP is banned — observed on BOTH
      // tile.openstreetmap.org and basemaps.cartocdn.com. Treat those as a
      // block: never cache them AND fail over to the next server so the map
      // keeps rendering.
      //
      // Only run the heuristic on block-prone hosts: other providers never
      // serve placeholders (they use real 403/429), and their real tiles can
      // legitimately be small and near-uniform (e.g. rural land at low zoom)
      // — flagging those would blank out whole areas.
      final host = _tileHost(template);
      final blockProne =
          host.contains('openstreetmap.org') ||
          host.contains('basemaps.cartocdn.com');
      if (blockProne && await _looksLikeBlockPlaceholder(res.bodyBytes)) {
        _blockedTileServers.add(template);
        debugPrint(
          'TILE: $host served a block placeholder '
          'for $key — switching server',
        );
        _serverIndex = (_serverIndex + 1) % _serverList.length;
        tried++;
        continue;
      }
      return res;
    } catch (e) {
      _failedTiles.add(key);
      debugPrint(
        'TILE: fetch failed $key from '
        '${_tileHost(template)}: $e',
      );
      return null;
    } finally {
      _tileInFlight--;
      _inFlightTiles.remove(key);
    }
  }
  return null; // every server failed for this tile
}

/// Heuristic for OSM-style "access blocked" placeholder tiles: a small PNG
/// whose pixels are nearly all one colour. Real map tiles are never uniform.
/// Only small payloads are decoded, so normal tiles skip this check.
Future<bool> _looksLikeBlockPlaceholder(Uint8List bytes) async {
  if (bytes.length > 3000) return false; // normal tiles are bigger
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final data = await img.toByteData();
    img.dispose();
    codec.dispose();
    if (data == null) return false;
    final px = data.buffer.asUint8List();
    final w = img.width;
    final h = img.height;
    if (w == 0 || h == 0) return false;
    final r0 = px[0], g0 = px[1], b0 = px[2];
    var same = 0, total = 0;
    for (var y = 0; y < h; y += 16) {
      for (var x = 0; x < w; x += 16) {
        final i = (y * w + x) * 4;
        if (i + 2 < px.length &&
            px[i] == r0 &&
            px[i + 1] == g0 &&
            px[i + 2] == b0) {
          same++;
        }
        total++;
      }
    }
    return total > 0 && same / total > 0.85;
  } catch (_) {
    return false; // can't decode — treat as a normal tile
  }
}

/// When true the app is locked to offline mode: tiles are only served from
/// disk (no network fetches), routing is on-device only and search is
/// cache-only. Toggled by the user (offline screen) and persisted.
bool forceOffline = false;

/// Vehicle used for speed-limit defaults: 'car' | 'motorbike' | 'truck'.
/// Persisted; applied on top of the road's OSM `maxspeed` (when tagged).
String vehicleType = 'car';

/// Online geocoding provider: 'photon' (Komoot, default — free, no key,
/// faster + better Vietnamese results) | 'nominatim' | 'vietmap' (Vietnam-
/// focused search — needs VIETMAP_API_KEY).
String geocodingProvider = 'photon';

/// Routing engine preference for car routes:
///   'auto'         — on-device GraphHopper graph when loaded, else OSRM.
///   'graphhopper'  — on-device graph only (fails fast if not loaded).
///   'osrm'         — always the online OSRM server.
String routingEngine = 'auto';

/// Google-style smooth map movement: a ticker eases the camera toward the
/// live (dead-reckoned) car position every frame instead of one ~500 ms jump
/// per 1 Hz GPS fix. Off → the old per-fix jump.
bool smoothCamera = true;

/// Riding mode: prefer the Bluetooth headset mic + short-command recognizer
/// model + longer wind-tolerant silence when recognizing voice commands on a
/// moving motorbike. Set by the UI (persisted in AppSettings.ridingMode) and
/// read by the speech recognizer.
bool ridingMode = false;

/// Spoken guidance volume (0.0–1.0, default 1.0). Shared global so the nav
/// voice + the settings pages read/write the same source of truth.
double voiceVolume = 1.0;

/// Always-on voice assistant wake word (default "dậy đi"). Customizable in
/// Settings because cheap phones' recognizers transcribe it differently — the
/// user sets whatever word their device actually hears. Read by the wake-word
/// matcher in VoiceCommands.
String wakeWord = 'dậy đi';

/// Simple nav mode: hide the map while navigating and show only a big
/// maneuver arrow + distance/ETA + voice commands (cleaner, lighter).
/// Set by the UI (persisted in AppSettings.simpleMode) and read by the nav
/// page to pick the simple layout.
bool simpleMode = false;

/// Speed/red-light camera alerts while navigating (phạt nguội DB). Shared
/// global (like [ridingMode]/[simpleMode]) so the nav-page toggle AND the
/// settings pages read/write the same source of truth — previously this was
/// page-local state, so saving any setting from the settings screens reset
/// it back to the default `true`.
bool cameraAlerts = true;

/// Camera VOICE warning while navigating — a SEPARATE toggle from the on-map
/// camera display ([cameraAlerts]): the voice stays ON by default even when
/// the camera icons / PiP chip on the map are switched off.
bool cameraVoice = true;

/// GPS outlier filter (innovation gate): reject fixes that are too inaccurate
/// or jump inconsistently with the recent smoothed speed before they reach
/// the map / complementary filter / speed chip. Off → raw fixes pass through
/// unfiltered (position/speed may jump). Shared global (same pattern as
/// [cameraAlerts]/[radarOn]) so the nav page AND settings read/write the same
/// source of truth.
bool gpsFilter = true;

/// Rain-radar overlay on the map (RainViewer, free/no key). Shared global
/// (same pattern as [cameraAlerts]) so the nav-page toggles AND settings
/// pages read/write the same source of truth.
bool radarOn = false;

/// Picture-in-Picture window shape while navigating (persisted):
///   'portrait' (9:16, default) | 'landscape' (4:3)
String pipAspect = '34';

/// Base URL for bulk region tile downloads.
///
/// MUST stay empty: bulk/pre-downloading whole regions from
/// Bulk region downloads go to a NON-OSM tile server. tile.openstreetmap.org
/// explicitly prohibits bulk/pre-downloading and has IP-banned this app before,
/// so the region downloader never touches it.
///
/// Default is CARTO's free basemaps (no API key — already used as the live-map
/// fallback). Point it at your own / licensed server at build time:
/// `flutter build apk --dart-define=TILE_URL=https://HOST/{z}/{x}/{y}.png`
/// Templates may use {z}/{x}/{y} and {s} (a/b/c subdomain balancing).
const String tileDownloadBaseUrl = String.fromEnvironment(
  'TILE_URL',
  defaultValue:
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
);

/// Human-readable label of the bulk-download tile source (shown in the UI).
String get tileDownloadSourceLabel {
  try {
    final host = Uri.parse(tileDownloadBaseUrl).host;
    return host.isEmpty ? 'máy chủ tile' : host;
  } catch (_) {
    return 'máy chủ tile';
  }
}

/// Average tile size (bytes) per zoom — used for pre-download size estimates.
const Map<int, int> _avgBytes = {
  0: 5000,
  1: 5000,
  2: 5000,
  3: 6000,
  4: 6000,
  5: 7000,
  6: 7000,
  7: 8000,
  8: 9000,
  9: 10000,
  10: 12000,
  11: 14000,
  12: 16000,
  13: 20000,
  14: 26000,
  15: 36000,
  16: 50000,
  17: 70000,
  18: 90000,
  19: 110000,
};

int _avgTileBytes(int z) => _avgBytes[z] ?? 30000;

// ---- online / offline --------------------------------------------------

/// True when the device has any connectivity.
///
/// NOTE: connectivity_plus misreports `none` on some ROMs (e.g. itel) even
/// when the network is up, which would make the map permanently blank. As a
/// fallback we simply TRY the fetch — a failed fetch is harmless (transparent
/// tile + failure-cache), but a false "offline" is a blank map forever.
Future<bool> isOnline() async {
  if (forceOffline) return false; // locked to offline mode
  try {
    final r = await Connectivity().checkConnectivity().timeout(
      const Duration(seconds: 4),
    );
    final ok = r.isNotEmpty && !r.contains(ConnectivityResult.none);
    if (!ok) {
      debugPrint(
        'TILE: connectivity_plus reported none — will still try '
        'the fetch',
      );
    }
    return true; // always try; only a real HTTP result tells the truth
  } catch (e) {
    debugPrint('TILE: connectivity check failed: $e — will still try');
    return true;
  }
}

/// Stream of connectivity changes (true = online).
Stream<bool> onlineStream() => Connectivity().onConnectivityChanged.map(
  (r) => r.isNotEmpty && !r.contains(ConnectivityResult.none),
);

// ---- slippy tile math --------------------------------------------------

int lonToTileX(double lon, int z) =>
    ((lon + 180.0) / 360.0 * math.pow(2, z)).floor();

int latToTileY(double lat, int z) {
  final r = lat * math.pi / 180.0;
  return ((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) /
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

/// Cache folder name for a tile layer source. The default ('osm') keeps the
/// legacy path so existing cached tiles stay valid; other sources get their
/// own sub-folder so switching basemap layers never mixes styles.
String _sourceDir(String? source) =>
    (source == null || source == 'osm') ? '' : '$source/';

Future<Directory> tileStoreDir({String? source}) async {
  await _ensureTileCacheVersion();
  final sup = await getApplicationSupportDirectory();
  final d = Directory('${sup.path}/offline_tiles/${_sourceDir(source)}');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

/// Bump when the tile-cache validation changes (e.g. a batch of poisoned
/// "access blocked" tiles was cached) — forces a one-time full cache clear.
const int tileCacheVersion = 3;
bool _tileVersionChecked = false;

Future<void> _ensureTileCacheVersion() async {
  if (_tileVersionChecked) return;
  _tileVersionChecked = true; // guard against recursion via clearTileCache
  try {
    final sup = await getApplicationSupportDirectory();
    final vf = File('${sup.path}/tile_cache_version');
    var v = 0;
    try {
      v = int.tryParse((await vf.readAsString()).trim()) ?? 0;
    } catch (_) {}
    if (v != tileCacheVersion) {
      await clearTileCache();
      await vf.writeAsString('$tileCacheVersion', flush: true);
      debugPrint('TILE: tile cache cleared (version $tileCacheVersion)');
    }
  } catch (_) {}
}

Future<File> tileFile(int z, int x, int y, {String? source}) async {
  final root = await tileStoreDir(source: source);
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
    for (final e in await root.list().toList()) {
      if (e is Directory) {
        await e.delete(recursive: true);
      } else if (e is File) {
        await e.delete();
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
        DateTime.tryParse((j['downloadedAt'] ?? '') as String) ??
        DateTime.now(),
  );
}

Future<List<OfflineRegion>> loadRegions() async {
  final sup = await getApplicationSupportDirectory();
  final f = File('${sup.path}/offline_regions.json');
  if (!await f.exists()) return [];
  try {
    final data = jsonDecode(await f.readAsString()) as List;
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
    jsonEncode([for (final r in rs) r.toJson()]),
    flush: true,
  );
}

// ---- downloader --------------------------------------------------------

/// Downloads all tiles of a region with progress + cancel support.
///
/// Uses a NON-OSM tile source ([tileDownloadBaseUrl] — default CARTO, or a
/// self-hosted/licensed server via `--dart-define=TILE_URL`), so it never
/// trips the OSM bulk-download ban. Single-threaded and rate-limited to keep
/// any public host happy.
class RegionDownloader {
  final OfflineRegion region;

  /// Basemap source folder to download into (see [tileStoreDir]). Default
  /// (null / 'osm') is the legacy shared path; pass the active map layer so
  /// downloaded tiles are actually read by that layer's provider.
  final String? source;

  int done = 0;
  int get total => region.tileCount;
  bool _cancel = false;
  int failed = 0;
  bool _blocked = false;
  bool get blocked => _blocked;
  bool get disabled => tileDownloadBaseUrl.isEmpty;

  RegionDownloader(this.region, {this.source});

  void cancel() => _cancel = true;

  Future<void> download(void Function(int done, int total) onProgress) async {
    if (tileDownloadBaseUrl.isEmpty) return; // no source configured
    done = 0;
    failed = 0;
    _blocked = false;
    final b = region.bounds;
    var lastRequest = DateTime.now();
    // ~3 tiles/s — fast enough for a useful download, gentle on public hosts.
    const minGap = Duration(milliseconds: 300);
    for (var z = region.minZoom; z <= region.maxZoom; z++) {
      if (_cancel) return;
      final x0 = lonToTileX(b.west, z);
      final x1 = lonToTileX(b.east, z);
      final y0 = latToTileY(b.north, z);
      final y1 = latToTileY(b.south, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (_cancel) return;
          final f = await tileFile(z, x, y, source: source);
          if (await f.exists()) {
            done++;
            continue;
          }
          // Respect the rate limit.
          final wait = minGap - DateTime.now().difference(lastRequest);
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
          }
          lastRequest = DateTime.now();
          try {
            final res = await http
                .get(
                  Uri.parse(_tileUrl(tileDownloadBaseUrl, z, x, y)),
                  headers: {'User-Agent': _ua},
                )
                .timeout(const Duration(seconds: 10));
            if (res.statusCode == 429 || res.statusCode == 403) {
              _blocked = true; // stop before we get IP-banned
              return;
            }
            // Only cache real PNG tiles (some servers return an HTML error
            // page with HTTP 200).
            if (res.statusCode == 200 &&
                res.bodyBytes.isNotEmpty &&
                _isPng(res.bodyBytes)) {
              await f.create(recursive: true);
              await f.writeAsBytes(res.bodyBytes);
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

  static bool _isPng(List<int> b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A;
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
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }
}

// ---- map tile provider -------------------------------------------------

/// Serves tiles from disk; when missing and online, downloads and caches
/// them; when missing and offline, shows a transparent tile. Each basemap
/// layer ([source]) caches under its own folder so layers never mix.
class OfflineTileProvider extends TileProvider {
  OfflineTileProvider({this.source = 'osm'}) : super();

  /// Basemap layer id (see navigation_page tile layer map).
  final String source;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      OfflineTileImage(coordinates, options, source);
}

class OfflineTileImage extends ImageProvider<OfflineTileImage> {
  final TileCoordinates coordinates;
  final TileLayer options;
  final String source;

  OfflineTileImage(this.coordinates, this.options, this.source);

  int get z => coordinates.z;
  int get x => coordinates.x;
  int get y => coordinates.y;

  @override
  Future<OfflineTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<OfflineTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    OfflineTileImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final file = await tileFile(z, x, y, source: source);
    if (await file.exists()) {
      try {
        // await so a decode failure is caught here (falls through to
        // re-download) instead of escaping the try block as an unhandled
        // future error.
        return await _decode(decode, await file.readAsBytes());
      } catch (_) {
        // corrupt tile — fall through to re-download
      }
    }
    debugPrint('TILE: loading $z/$x/$y (no cache)');
    if (await isOnline()) {
      // Rate-limited + serialized so we stay under the OSM tile policy,
      // with automatic failover to other free OSM tile servers when one
      // blocks us (403/429 — e.g. an IP ban).
      final res = await _fetchTile(z, x, y, options.urlTemplate ?? '', source);
      if (res != null && res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        await file.create(recursive: true);
        await file.writeAsBytes(res.bodyBytes);
        return _decode(decode, res.bodyBytes);
      }
      // fall through to transparent tile
    }
    return _decode(decode, TileProvider.transparentImage);
  }

  Future<ImageInfo> _decode(
    ImageDecoderCallback decode,
    Uint8List bytes,
  ) async {
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
      other.y == y &&
      other.source == source;

  @override
  int get hashCode => Object.hash(source, z, x, y);
}
