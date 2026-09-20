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
    show fetchOnlineTileBytes, tileFile, isOnline, forceOffline;
import 'package:navbridge/services/vietmap_config.dart'
    show VietmapConfig, appendCartoApiKey;

class NavTileServer {
  NavTileServer._();
  static final NavTileServer instance = NavTileServer._();

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
      case 'osm':
        return const [
          'https://a.tile.openstreetmap.org/{z}/{x}/{y}.png',
          'https://b.tile.openstreetmap.org/{z}/{x}/{y}.png',
          'https://c.tile.openstreetmap.org/{z}/{x}/{y}.png',
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
    // 1. Local disk cache hit (bundled overview tiles + region downloads + auto-cached tiles).
    try {
      final cacheFile = await tileFile(z, x, y, source: activeSource);
      if (await cacheFile.exists()) {
        final b = await cacheFile.readAsBytes();
        if (_isPng(b)) return b;
        final png = await _normalizePng(b);
        if (png != null) return png;
      }
      if (activeSource != 'overview') {
        final of = await tileFile(z, x, y, source: 'overview');
        if (await of.exists()) {
          final b = await of.readAsBytes();
          if (_isPng(b)) return b;
          final png = await _normalizePng(b);
          if (png != null) return png;
        }
      }
    } catch (e) {
      debugPrint('TILESRV: cache read error $z/$x/$y: $e');
    }

    // 2. Online fetch when connected.
    final online = !forceOffline && await isOnline();
    if (online) {
      final fetched = await _fetchOnline(z, x, y, source: activeSource);
      if (fetched != null) return fetched;
    }

    // 3. Transparent fallback (keeps MapLibre from erroring out).
    return await _transparentPng();
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
