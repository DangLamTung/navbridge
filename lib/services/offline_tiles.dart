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

import 'package:archive/archive.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'vietmap_config.dart' show appendCartoApiKey;

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

/// Minimum gap between tile requests PER SOURCE. Paced at 200ms with concurrency
/// <= 2 threads so viewport tile sets load swiftly while remaining within
/// polite client conventions. Other free providers (CARTO / ESRI / topo) allow
/// a faster 40ms rate.
const Duration _osmMinTileGap = Duration(milliseconds: 200);
const Duration _fastMinTileGap = Duration(milliseconds: 40);

/// How long to pause fetches when all servers for a source have blocked us.
const Duration _blockBackoff = Duration(seconds: 60);

/// True when [b] begins with the PNG magic bytes. Used to reject a tile server
/// that returns an HTML error page / "access blocked" placeholder with HTTP 200
/// (those are never cached).
bool _isPngBytes(List<int> b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

/// True when [b] looks like a decodable raster image (PNG or JPEG). ESRI
/// World Imagery (and some satellite/topo servers) serve JPEG, not PNG —
/// a PNG-only check silently dropped every ESRI tile, so the satellite
/// basemap rendered nothing. JPEG starts with 0xFF 0xD8 0xFF; PNG with the
/// magic above. Rejects HTML/JSON error pages (they don't start like either).
bool _isImageBytes(List<int> b) =>
    _isPngBytes(b) ||
    (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF);

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

/// Last request time per source, so OSM keeps its ~1 tile/s policy while
/// faster providers aren't held back by a shared global clock.
final Map<String, DateTime> _lastTileRequestBySource = {};
DateTime _tileBlockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
int _tileInFlight = 0;
final Set<String> _inFlightTiles = {};
final Map<String, DateTime> _failedTiles = {};
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
  return appendCartoApiKey(url);
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
  final now = DateTime.now();
  if (_tileBlockedUntil.isAfter(now)) return null; // all blocked
  final failedAt = _failedTiles[key];
  if (failedAt != null &&
      now.difference(failedAt) < const Duration(seconds: 30)) {
    return null;
  }
  // Keep the failed-tile map bounded: once it grows past a threshold, drop the
  // entries whose 30 s retry window has already passed.
  if (_failedTiles.length > 2000) {
    _failedTiles.removeWhere(
      (k, at) => now.difference(at) >= const Duration(seconds: 30),
    );
  }
  if (_inFlightTiles.contains(key)) return null;

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
    // Respect the per-source rate: OSM ~1 tile/s (policy), others faster.
    final minGap = source == 'osm' ? _osmMinTileGap : _fastMinTileGap;
    final lastReq = _lastTileRequestBySource[source];
    if (lastReq != null) {
      final wait = minGap - DateTime.now().difference(lastReq);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }

    _tileInFlight++;
    _inFlightTiles.add(key);
    _lastTileRequestBySource[source] = DateTime.now();
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
        _failedTiles[key] =
            DateTime.now(); // don't immediately re-request the same missing tile
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
      _failedTiles[key] = DateTime.now();
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

/// Public, OSM-policy-aware online tile fetch used by the MapLibre nav map's
/// loopback tile server ([NavTileServer]). Returns the raw downloaded bytes
/// for [z]/[x]/[y] (or null when every server failed).
///
/// Unlike a naive `http.get`, this routes through [_fetchTile], so it honours
/// the OSM tile policy (<= 2 concurrent, ~1 tile/s), fails over across the
/// style-matched servers, detects 403/429 blocks AND the "access blocked"
/// placeholder that OSM/CARTO serve with HTTP 200, and never caches HTML
/// error pages. Without this the nav map's pan/zoom fired an unthrottled
/// burst at OSM and got rate-limited → a blank basemap (the OSM-not-working
/// bug).
Future<Uint8List?> fetchOnlineTileBytes(
  int z,
  int x,
  int y, {
  required String template,
  required String source,
}) async {
  final res = await _fetchTile(z, x, y, template, source);
  if (res == null || res.statusCode != 200 || res.bodyBytes.isEmpty) {
    return null;
  }
  return res.bodyBytes;
}

/// When true the app is locked to offline mode: tiles are only served from
/// disk (no network fetches), routing is on-device only and search is
/// cache-only. Toggled by the user (offline screen) and persisted.
bool forceOffline = false;

/// How the current speed + posted limit are drawn WHILE NAVIGATING:
///   'chip' — compact white chip with two small dials (default)
///   'dial' — the floating speed widget's round gauge (orange→red tick sweep,
///            big weight-900 number) with the P.127 limit sign overlapping it.
/// Set in Settings → "Hiển thị tốc độ"; persisted in AppSettings.navSpeedStyle.
/// Default is the floating widget's round gauge ('dial') — the compact chip is
/// the opt-in.
String navSpeedStyle = 'dial';

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
  await ensureOverviewTilesExtracted();
  final sup = await getApplicationSupportDirectory();
  final d = Directory('${sup.path}/offline_tiles/${_sourceDir(source)}');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

bool _overviewExtracted = false;

/// Extracts the bundled Vietnam overview tiles ($z=0 \to z=8$) from the asset
/// archive (`assets/offline_map/overview_tiles.tar.gz`) into local storage on
/// first launch. Ensures zoomed-out map views never go blank even 100% offline.
Future<void> ensureOverviewTilesExtracted() async {
  if (_overviewExtracted) return;
  _overviewExtracted = true;
  try {
    final sup = await getApplicationSupportDirectory();
    final marker = File('${sup.path}/offline_tiles/.overview_extracted');
    final overviewDir = Directory('${sup.path}/offline_tiles/overview');
    if (marker.existsSync() &&
        overviewDir.existsSync() &&
        overviewDir.listSync().isNotEmpty) {
      return;
    }

    final bytes = await rootBundle.load(
      'assets/offline_map/overview_tiles.tar.gz',
    );
    final rawBytes = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final decompressed = GZipDecoder().decodeBytes(rawBytes);
    final archive = TarDecoder().decodeBytes(decompressed);

    final cartoDir = Directory('${sup.path}/offline_tiles/carto');
    final osmDir = Directory('${sup.path}/offline_tiles');

    for (final file in archive) {
      if (!file.isFile) continue;
      final content = file.content as List<int>;
      final name = file.name.startsWith('./')
          ? file.name.substring(2)
          : file.name;
      if (!name.endsWith('.png')) continue;
      // Defense-in-depth: the tar is a bundled, trusted app asset, but never
      // let an entry escape the target dirs (no parent `..`, no absolute
      // path, no backslash) — a future user-supplied archive must not be able
      // to write outside `<support>/offline_tiles` (path traversal / zip-slip).
      final segs = name.split('/');
      if (segs.any((s) => s == '..' || s.isEmpty || s.contains('\\'))) {
        continue;
      }

      for (final dir in [overviewDir, cartoDir, osmDir]) {
        final outFile = File('${dir.path}/$name');
        if (!outFile.existsSync()) {
          outFile.createSync(recursive: true);
          outFile.writeAsBytesSync(content, flush: true);
        }
      }
    }
    marker.createSync(recursive: true);
    debugPrint('TILE: overview tiles (z0-z8) extracted successfully');
  } catch (e) {
    debugPrint('TILE: overview tiles extraction note: $e');
  }
}

/// Bump when the tile-cache validation changes (e.g. a batch of poisoned
/// "access blocked" tiles was cached) — forces a one-time full cache clear.
const int tileCacheVersion = 4;
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
  try {
    await for (final f in root.list(recursive: true)) {
      if (f is File && f.path.endsWith('.png')) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

/// Remove every stored tile (auto-cache + downloaded regions).
/// Preserves bundled overview tiles so zoomed-out maps never go blank.
Future<void> clearTileCache() async {
  final root = await tileStoreDir();
  _overviewExtracted = false;
  try {
    for (final e in await root.list().toList()) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == 'overview' || name == '.overview_extracted') continue;
      if (e is Directory) {
        await e.delete(recursive: true);
      } else if (e is File) {
        await e.delete();
      }
    }
  } catch (_) {}
  await ensureOverviewTilesExtracted();
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

  /// Tiles that actually exist after the run (already cached OR freshly
  /// written). A region is only worth remembering when this is > 0.
  int success = 0;
  bool _blocked = false;
  bool get blocked => _blocked;
  bool get disabled => tileDownloadBaseUrl.isEmpty;

  RegionDownloader(this.region, {this.source});

  void cancel() => _cancel = true;

  Future<void> download(void Function(int done, int total) onProgress) async {
    if (tileDownloadBaseUrl.isEmpty) return; // no source configured
    done = 0;
    failed = 0;
    success = 0;
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
            success++;
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
              success++;
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

/// Remove every tile belonging to [r] from the store — from BOTH the root
/// (auto-cached tiles for the active source) and the 'carto' source dir (the
/// bulk-downloaded regions).
Future<void> deleteRegion(OfflineRegion r) async {
  final root = await tileStoreDir();
  final carto = await tileStoreDir(source: 'carto');
  final b = r.bounds;
  for (var z = r.minZoom; z <= r.maxZoom; z++) {
    final x0 = lonToTileX(b.west, z);
    final x1 = lonToTileX(b.east, z);
    final y0 = latToTileY(b.north, z);
    final y1 = latToTileY(b.south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        for (final dir in [root, carto]) {
          try {
            final f = File('${dir.path}/$z/$x/$y.png');
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
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

  // Fast in-memory LRU cache of recently decoded tile images (0 ms retrieval).
  static final Map<String, Uint8List> _memCache = {};
  static final List<String> _memCacheOrder = [];
  static const int _maxMemCache = 160;

  static Uint8List? _getFromMem(String key) {
    final v = _memCache[key];
    if (v != null) {
      _memCacheOrder.remove(key);
      _memCacheOrder.add(key);
    }
    return v;
  }

  static void _putToMem(String key, Uint8List bytes) {
    if (_memCache.containsKey(key)) {
      _memCacheOrder.remove(key);
    } else if (_memCache.length >= _maxMemCache && _memCacheOrder.isNotEmpty) {
      final oldest = _memCacheOrder.removeAt(0);
      _memCache.remove(oldest);
    }
    _memCache[key] = bytes;
    _memCacheOrder.add(key);
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final keyStr = '$source/$z/$x/$y';

    // 1. In-memory LRU cache hit (0 ms — instant render during panning/zooming).
    final mem = _getFromMem(keyStr);
    if (mem != null) {
      try {
        return await _decode(decode, mem);
      } catch (_) {
        _memCache.remove(keyStr);
        _memCacheOrder.remove(keyStr);
      }
    }

    // 2. Local disk cache hit (1-2 ms).
    // Look in the active source dir first; if missing, check 'carto' (for OSM)
    // and bundled 'overview'.
    var file = await tileFile(z, x, y, source: source);
    if (!await file.exists() && source == 'osm') {
      file = await tileFile(z, x, y, source: 'carto');
    }
    if (!await file.exists() && source != 'overview') {
      final of = await tileFile(z, x, y, source: 'overview');
      if (await of.exists()) file = of;
    }
    if (await file.exists()) {
      try {
        final b = await file.readAsBytes();
        _putToMem(keyStr, b);
        return await _decode(decode, b);
      } catch (_) {
        // corrupt tile on disk — fall through to re-download
      }
    }

    // 3. Online fetch (only when missing on disk and connected).
    if (!forceOffline && await isOnline()) {
      final res = await _fetchTile(z, x, y, options.urlTemplate ?? '', source);
      if (res != null &&
          res.statusCode == 200 &&
          res.bodyBytes.isNotEmpty &&
          _isImageBytes(res.bodyBytes)) {
        try {
          final f = await tileFile(z, x, y, source: source);
          await f.create(recursive: true);
          await f.writeAsBytes(res.bodyBytes);
        } catch (_) {}
        _putToMem(keyStr, res.bodyBytes);
        try {
          return await _decode(decode, res.bodyBytes);
        } catch (_) {}
      }
    }

    // 4. Missing tile fallback: cached synthesized tile, or a parent-tile
    // upsample (crop + upscale the nearest available ancestor). This keeps a
    // large-zoom/offline map from going blank: instead of a transparent tile,
    // we zoom into the closest tile we DO have. Works at ANY zoom (not just
    // z<=12) so deep zoom-in still shows image-filled detail from an ancestor.
    if (z >= 1) {
      final synthFile = await tileFile(z, x, y, source: 'synth');
      if (await synthFile.exists()) {
        try {
          final b = await synthFile.readAsBytes();
          _putToMem(keyStr, b);
          return await _decode(decode, b);
        } catch (_) {}
      }
      // Top out the ancestor walk at a sane depth: zooming to z=20 with an
      // only-z10 overview would otherwise recurse 10 levels every frame for
      // every tile. 5 levels up (~5x) is plenty to fill a missing tile while
      // staying cheap on the low-end phone.
      final synthesized = await _trySynthesizeFromParent(
        z,
        x,
        y,
        source,
        maxDepth: 6,
      );
      if (synthesized != null) {
        try {
          await synthFile.create(recursive: true);
          await synthFile.writeAsBytes(synthesized, flush: true);
        } catch (_) {}
        _putToMem(keyStr, synthesized);
        return _decode(decode, synthesized);
      }
    }

    return _decode(decode, TileProvider.transparentImage);
  }

  static Future<Uint8List?> _getTileBytes(
    int z,
    int x,
    int y,
    String source,
  ) async {
    for (final src in [source, 'carto', 'overview']) {
      final f = await tileFile(z, x, y, source: src);
      if (await f.exists()) {
        try {
          return await f.readAsBytes();
        } catch (_) {}
      }
    }
    return null;
  }


  /// Synthesizes a missing tile by cropping and upsampling from its parent tile at $z-1$.
  /// Synthesizes a missing tile by cropping and upsampling from the nearest
  /// available ancestor tile (parent at $z-1, grandparent at $z-2, … up to
  /// [maxDepth] levels up). Deep zoom / offline gaps never go blank: we zoom
  /// into whatever tile we actually have. The crop region grows with depth so
  /// the final 256×256 is always filled.
  static Future<Uint8List?> _trySynthesizeFromParent(
    int z,
    int x,
    int y,
    String source, {
    int maxDepth = 6,
  }) async {
    for (var up = 1; up <= maxDepth; up++) {
      final az = z - up;
      if (az <= 0) break;
      final ax = x >> up;
      final ay = y >> up;
      final aBytes = await _getTileBytes(az, ax, ay, source);
      if (aBytes == null) continue;

      // The region of the ancestor tile that maps to this (z,x,y) tile. At
      // depth `up` the ancestor is 2^up times coarser, so this tile is a
      // (256 / 2^up) square inside it.
      final cells = 1 << up; // 2^up
      final cell = 256 ~/ cells;
      final srcX = (x & (cells - 1)) * cell;
      final srcY = (y & (cells - 1)) * cell;
      final syn = await _cropUpscale(aBytes, srcX, srcY, cell, 256);
      if (syn != null) return syn;
      // If the ancestor decoded but cropping failed, keep walking up.
    }
    return null;
  }

  /// Decodes [bytes] then crops a [srcX],[srcY],[srcSize] square and scales it
  /// up to [outSize]×[outSize], re-encoding to PNG. Returns null on any error.
  static Future<Uint8List?> _cropUpscale(
    Uint8List bytes,
    int srcX,
    int srcY,
    int srcSize,
    int outSize,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec(
        targetWidth: outSize,
        targetHeight: outSize,
      );
      final frame = await codec.getNextFrame();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble()),
      );
      canvas.drawImageRect(
        frame.image,
        Rect.fromLTWH(srcX.toDouble(), srcY.toDouble(), srcSize.toDouble(),
            srcSize.toDouble()),
        Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      frame.image.dispose();
      codec.dispose();

      final picture = recorder.endRecording();
      final img = await picture.toImage(outSize, outSize);
      picture.dispose();
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
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
