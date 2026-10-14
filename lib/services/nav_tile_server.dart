/// Local (loopback) raster tile server for the MapLibre nav map.
///
/// The low-end itel's MapLibre build fails to decode tiles that MapLibre
/// fetches itself over HTTP (`bitmap decoding: couldn't get bitmap info`),
/// which left the online nav basemap blank for **every** online source. The
/// app's own HTTP client works fine and the offline `file://` (PNG) basemap
/// renders — so this server fetches tiles through the app, normalises every
/// response to a decodable PNG, caches it, and serves MapLibre a single
/// `http://127.0.0.1:<port>/tiles/{z}/{x}/{y}.png` endpoint. It is
/// source-agnostic: online OSM/CARTO/ESRI, offline file cache and synthetic
/// tiles all come through the same URL.
///
/// Only bound to loopback (`127.0.0.1`) so it is never reachable from the
/// network. A singleton kept alive for the app lifetime (both PiP + full-screen
/// VectorNavMap instances share it); call [update] when the tile source changes
/// and never stop it mid-navigation.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:navbridge/services/offline_tiles.dart'
    show
        fetchOnlineTileBytes,
        tileFile,
        isDefinitelyOffline,
        forceOffline;
import 'package:navbridge/services/vietmap_config.dart'
    show VietmapConfig, appendCartoApiKey;

class NavTileServer {
  NavTileServer._();
  static final NavTileServer instance = NavTileServer._();

  /// One-shot so the offline notice is not repeated per tile.
  bool _loggedOfflineTiles = false;

  HttpServer? _server;
  int? _port;
  bool _starting = false;
  Future<int>? _startFuture;

  /// Online tile URL templates for the active source (e.g. from
  /// `_fallbackTiles()`); each may use `{z}/{x}/{y}` in any order.
  List<String> _templates = const [];

  /// Offline cache source folder ('' for the OSM root, else the source name).
  String? _sourceName;

  int? get port => _port;
  bool get isRunning => _server != null;

  /// Map a known tile source to its online raster templates.
  static List<String> templatesForSource(String source, {bool nightMode = false}) {
    switch (source) {
      // No templates BY DESIGN: this source is the on-device data — the vector
      // archive plus whatever raster tiles were downloaded. Without an explicit
      // case it fell through to `default:` (CARTO) and fetched online tiles,
      // which is the exact opposite of what "offline" promises.
      case 'offline':
        return const [];
      case 'osm':
        // Mirrors AFTER the primary, so a rate limit / IP block on the
        // volunteer servers fails over instead of leaving the nav basemap
        // blank (see the same list in `offline_tiles.dart`).
        return const [
          'https://a.tile.openstreetmap.org/{z}/{x}/{y}.png',
          'https://b.tile.openstreetmap.org/{z}/{x}/{y}.png',
          'https://c.tile.openstreetmap.org/{z}/{x}/{y}.png',
          'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
          'https://a.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          'https://b.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
          'https://c.tile.openstreetmap.fr/osmfr/{z}/{x}/{y}.png',
        ];
      case 'topo':
        return const ['https://tile.opentopomap.org/{z}/{x}/{y}.png'];
      case 'esri':
        return const [
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Imagery/MapServer/tile/{z}/{y}/{x}',
        ];
      case 'esri-street':
        return const [
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Street_Map/MapServer/tile/{z}/{y}/{x}',
        ];
      case 'carto-light':
        return [
          appendCartoApiKey(
            'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://b.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://c.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://d.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          ),
        ];
      case 'carto-dark':
        return [
          appendCartoApiKey(
            'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://b.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://c.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://d.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
          ),
        ];
      case 'vietmap':
        if (VietmapConfig.hasKeys) return [VietmapConfig.mapTiles];
        return templatesForSource('osm', nightMode: nightMode);
      case 'vietmapsat':
        if (VietmapConfig.hasKeys) return [VietmapConfig.satelliteTiles];
        return templatesForSource('esri', nightMode: nightMode);
      case 'vector':
      case 'carto':
      default:
        final style = nightMode ? 'dark_all' : 'rastertiles/voyager';
        return [
          appendCartoApiKey(
            'https://a.basemaps.cartocdn.com/$style/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://b.basemaps.cartocdn.com/$style/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://c.basemaps.cartocdn.com/$style/{z}/{x}/{y}.png',
          ),
          appendCartoApiKey(
            'https://d.basemaps.cartocdn.com/$style/{z}/{x}/{y}.png',
          ),
        ];
    }
  }

  /// Start (idempotent) and return the loopback port. Keeps the server alive
  /// for the app lifetime.
  Future<int> ensureStarted({
    required List<String> templates,
    String? sourceName,
    bool? nightMode,
  }) async {
    update(
      templates: templates,
      sourceName: sourceName,
      nightMode: nightMode,
    );
    if (_server != null) return _port!;
    if (_starting) return _startFuture!;
    _starting = true;
    _startFuture = _doStart();
    try {
      return await _startFuture!;
    } finally {
      _starting = false;
    }
  }

  Future<int> _doStart() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    server.listen(
      _handle,
      onError: (Object e) {
        debugPrint('TILESRV: error: $e');
      },
    );
    debugPrint('TILESRV: listening on 127.0.0.1:${server.port}');
    return _port!;
  }

  bool _nightMode = false;

  /// Update the active source templates / cache folder without restarting.
  void update({
    required List<String> templates,
    String? sourceName,
    bool? nightMode,
  }) {
    _templates = List<String>.unmodifiable(templates);
    _sourceName = sourceName;
    if (nightMode != null) _nightMode = nightMode;
  }

  /// Shut the server down (only used in tests / teardown).
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
  }

  /// Max Web-Mercator zoom we will ever serve. Bounds tile coordinates so a
  /// malformed / abusive request can't create unbounded cache paths (e.g.
  /// `/tiles/99999/…`) or trigger huge/meaningless upstream fetches.
  static const int _maxZoom = 22;

  // ---- request handling ------------------------------------------------
  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        _write(req, 405, const [], contentType: 'text/plain');
        return;
      }
      // Path like /tiles/15/26218/15090.png (4 parts) OR /tiles/esri/15/26218/15090.png (5 parts)
      final parts = req.uri.path.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.length < 4 || parts[0] != 'tiles') {
        _write(req, 404, const [], contentType: 'text/plain');
        return;
      }
      final String? reqSource;
      final int? z, x, y;
      if (parts.length >= 5) {
        reqSource = parts[1];
        z = int.tryParse(parts[2]);
        x = int.tryParse(parts[3]);
        var ys = parts[4];
        if (ys.endsWith('.png')) ys = ys.substring(0, ys.length - 4);
        y = int.tryParse(ys);
      } else {
        reqSource = _sourceName;
        z = int.tryParse(parts[1]);
        x = int.tryParse(parts[2]);
        var ys = parts[3];
        if (ys.endsWith('.png')) ys = ys.substring(0, ys.length - 4);
        y = int.tryParse(ys);
      }
      if (z == null ||
          x == null ||
          y == null ||
          z < 0 ||
          z > _maxZoom ||
          x < 0 ||
          y < 0) {
        _write(req, 400, const [], contentType: 'text/plain');
        return;
      }
      final max = 1 << z;
      if (x >= max || y >= max) {
        _write(req, 400, const [], contentType: 'text/plain');
        return;
      }
      final bytes = await _resolve(z, x, y, source: reqSource);
      _write(req, 200, bytes, contentType: 'image/png');
    } catch (e) {
      debugPrint('TILESRV: handle error: $e');
      try {
        _write(req, 500, const [], contentType: 'text/plain');
      } catch (_) {}
    }
  }

  void _write(
    HttpRequest req,
    int status,
    List<int> body, {
    String contentType = 'image/png',
  }) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.parse(contentType);
    req.response.add(body);
    req.response.close().catchError((_) {});
  }

  // ---- tile resolution ------------------------------------------------
  Future<Uint8List> _resolve(int z, int x, int y, {String? source}) async {
    final activeSource = source ?? _sourceName;

    // 1. The SELECTED source's OWN cache (auto-cached online tiles + region
    //    downloads for that source). Same provider as the live tile, so serving
    //    it costs nothing in look and saves the request.
    final own = await _cachedTile(z, x, y, activeSource);
    if (own != null) return own;

    // 2. Online fetch when connected — and NOT when the platform already says
    //    there is no connection: `isOnline()` always returns true on purpose
    //    (only a real HTTP result is trusted for routing), so asking it here
    //    made every uncached tile wait for a fetch that could not succeed.
    final online = !forceOffline && !await isDefinitelyOffline();
    if (online) {
      final fetched = await _fetchOnline(z, x, y, source: activeSource);
      if (fetched != null) return fetched;
    } else if (!_loggedOfflineTiles) {
      _loggedOfflineTiles = true;
      debugPrint('TILESRV: offline — serving cached tiles only');
    }

    // 3. ⭐ The bundled BULK OVERVIEW pack — only NOW, after the network.
    //
    // It is a DIFFERENT provider from the selected source: `overview_tiles
    // .tar.gz` was captured from CARTO. Serving it from the disk cache AHEAD of
    // the online fetch (which is what this used to do, for every source) meant
    // an OSM / vector selection rendered CARTO tiles at the pack's zooms
    // (z0-z8) even with a working connection — reported 2026-10-14: "my map
    // still fallback to using the carto even when have the network". It is a
    // last resort for offline / failed fetches, which is what it is for.
    if (activeSource != 'overview') {
      final ov = await _cachedTile(z, x, y, 'overview');
      if (ov != null) return ov;
    }

    // 4. Transparent fallback (keeps MapLibre from erroring out).
    return await _transparentPng();
  }

  /// One cached tile from [source]'s store, normalised to a decodable PNG, or
  /// null when it is not on disk / cannot be decoded. [source] is nullable to
  /// match [tileFile] (a null source is the store's root, as before).
  Future<Uint8List?> _cachedTile(int z, int x, int y, String? source) async {
    try {
      final f = await tileFile(z, x, y, source: source);
      if (!await f.exists()) return null;
      final b = await f.readAsBytes();
      if (_isPng(b)) return b;
      return await _normalizePng(b);
    } catch (e) {
      debugPrint('TILESRV: cache read error $z/$x/$y ($source): $e');
      return null;
    }
  }

  /// Try every online template; returns a decodable PNG (and caches it) or
  /// null when every source failed.
  Future<Uint8List?> _fetchOnline(int z, int x, int y, {String? source}) async {
    final tpls = (source != null && source.isNotEmpty)
        ? templatesForSource(source, nightMode: _nightMode)
        : _templates;
    final srcName = source ?? _sourceName;
    for (final tpl in tpls) {
      if (tpl.isEmpty) continue;
      // Route through the OSM-policy-aware fetcher (offline_tiles.dart) so the
      // nav basemap respects OSM's <=2-concurrent / ~1-tile/s limit, fails
      // over across servers and rejects the "access blocked" placeholder.
      // A naive raw http.get here fired an unthrottled burst at OSM during
      // pan/zoom → 403/429 → blank map.
      try {
        final body = await fetchOnlineTileBytes(
          z,
          x,
          y,
          template: tpl,
          source: srcName ?? 'osm',
        );
        if (body == null) continue;
        final png = await _normalizePng(body);
        if (png != null) {
          try {
            final cacheFile = await tileFile(z, x, y, source: srcName);
            await cacheFile.parent.create(recursive: true);
            await cacheFile.writeAsBytes(png, flush: true);
          } catch (e) {
            debugPrint('TILESRV: cache write error $z/$x/$y: $e');
          }
          return png;
        }
      } catch (e) {
        debugPrint('TILESRV: fetch error $tpl $z/$x/$y: $e');
      }
    }
    return null;
  }

  /// True if [bytes] begin with the PNG magic.
  bool _isPng(Uint8List b) =>
      b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  /// Returns a PNG copy of [bytes]; null if it can't be decoded as an image.
  Future<Uint8List?> _normalizePng(Uint8List bytes) async {
    if (_isPng(bytes)) return bytes; // already a decodable PNG
    try {
      return await _toPng(bytes);
    } catch (e) {
      debugPrint('TILESRV: decode failed (${bytes.length} bytes): $e');
      return null;
    }
  }

  /// Decode any raster image and re-encode as PNG.
  Future<Uint8List> _toPng(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static final Uint8List _transparentPngBytes = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // 8-bit RGBA
    0x89,                                           // IHDR crc
    0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, // IDAT
    0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, // payload
    0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F,       // IDAT crc
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
    0xAE, 0x42, 0x60, 0x82,                         // IEND crc
  ]);

  Future<Uint8List> _transparentPng() async => _transparentPngBytes;
}
