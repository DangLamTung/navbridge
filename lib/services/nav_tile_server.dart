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
import 'package:http/http.dart' as http;

import 'package:navbridge/services/offline_tiles.dart' show tileFile;

/// User-Agent for the tile requests (OSM tile policy requires a stable,
/// app-naming UA).
const String _tileUA =
    'NavBridge/1.0 (Android; BLE portable navigation; online map display)';

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

  Uint8List? _transparent;

  int? get port => _port;
  bool get isRunning => _server != null;

  /// Start (idempotent) and return the loopback port. Keeps the server alive
  /// for the app lifetime.
  Future<int> ensureStarted({
    required List<String> templates,
    String? sourceName,
  }) async {
    update(templates: templates, sourceName: sourceName);
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

  /// Update the active source templates / cache folder without restarting.
  void update({required List<String> templates, String? sourceName}) {
    _templates = List<String>.unmodifiable(templates);
    _sourceName = sourceName;
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
      // Path like /tiles/15/26218/15090.png
      final parts = req.uri.path.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.length < 4 || parts[0] != 'tiles') {
        _write(req, 404, const [], contentType: 'text/plain');
        return;
      }
      final z = int.tryParse(parts[1]);
      final x = int.tryParse(parts[2]);
      var ys = parts[3];
      if (ys.endsWith('.png')) ys = ys.substring(0, ys.length - 4);
      final y = int.tryParse(ys);
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
      final bytes = await _resolve(z, x, y);
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
  Future<Uint8List> _resolve(int z, int x, int y) async {
    // 1. Local cache (bundled overview tiles + region downloads + auto-cached
    //    tiles, matching the offline basemap path) — served raw.
    File? cacheFile;
    try {
      cacheFile = await tileFile(z, x, y, source: _sourceName);
      if (await cacheFile.exists()) {
        final b = await cacheFile.readAsBytes();
        if (_isPng(b) || await _decodeable(b)) return b;
      }
    } catch (e) {
      debugPrint('TILESRV: cache read error $z/$x/$y: $e');
    }

    // 2. Online fetch via the app's HTTP client, normalised to PNG + cached.
    for (final tpl in _templates) {
      if (tpl.isEmpty) continue;
      final url = _fill(tpl, z, x, y);
      try {
        final resp = await http
            .get(Uri.parse(url), headers: {'User-Agent': _tileUA})
            .timeout(const Duration(seconds: 8));
        final body = resp.bodyBytes;
        if (resp.statusCode == 200 && body.isNotEmpty) {
          final png = await _normalizePng(body);
          if (png != null) {
            try {
              cacheFile ??= await tileFile(z, x, y, source: _sourceName);
              await cacheFile.parent.create(recursive: true);
              await cacheFile.writeAsBytes(png, flush: true);
            } catch (e) {
              debugPrint('TILESRV: cache write error $z/$x/$y: $e');
            }
            return png;
          }
        }
      } catch (e) {
        debugPrint('TILESRV: fetch error $url: $e');
      }
    }

    // 3. Transparent fallback (keeps MapLibre from erroring out).
    return await _transparentPng();
  }

  /// Fill {z}/{x}/{y} in a template, preserving the template's own order
  /// (ESRI uses {z}/{y}/{x}, OSM uses {z}/{x}/{y}).
  String _fill(String tpl, int z, int x, int y) => tpl
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');

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

  Future<bool> _decodeable(Uint8List bytes) async {
    if (_isPng(bytes)) return true;
    try {
      await _toPng(bytes);
      return true;
    } catch (_) {
      return false;
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

  Future<Uint8List> _transparentPng() async {
    final cached = _transparent;
    if (cached != null) return cached;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..color = const ui.Color(0x00000000);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 256, 256), paint);
    final img = await recorder.endRecording().toImage(256, 256);
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      _transparent = bd!.buffer.asUint8List();
      return _transparent!;
    } finally {
      img.dispose();
    }
  }
}
