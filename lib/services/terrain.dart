/// Offline Digital Elevation Model (DEM) — powers 3D terrain rendering on the
/// navigation map AND offline elevation (ascent/descent) for routes, so
/// mountain travel works with no network at all.
///
/// Data source: AWS **Terrarium** terrain tiles (free, public S3, no key).
/// Each tile is a PNG whose RGB pixels are RGB-encoded elevation:
/// `elev = (r*256 + g + b/256) - 32768` meters. Tiles are downloaded for an
/// offline region (like the map tiles) and stored under
/// `<support>/nav_map/terrain/{z}/{x}/{y}.png`, then served straight from
/// disk to MapLibre as a `raster-dem` source (3D) and sampled directly for
/// elevation profiles.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_tiles.dart' show lonToTileX, latToTileY;

/// Public AWS Terrarium DEM tile template (no API key).
/// ~30 m/pixel SRTM (global) → z0..z15; we download up to z13 (~38 m/px).
const String kTerrainTileUrl =
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png';

/// Downloaded terrarium tiles live under this folder (inside the support dir).
const String kTerrainDir = 'nav_map/terrain';

/// Zoom range for the offline terrain download. z4..z13 keeps the download
/// small enough for a region while still giving relief + a route profile.
const int kTerrainMinZoom = 4;
const int kTerrainMaxZoom = 13;

const String _ua = 'navbridge/1.0 (offline terrain)';

/// Decode a Terrarium RGB pixel to elevation in meters.
double terrariumDecode(int r, int g, int b) => (r * 256 + g + b / 256) - 32768;

/// Returns a deep copy of [baseStyle] with (or without) the terrain block
/// + `raster-dem` source injected, depending on [enabled] and [demSource].
///
/// Terrain is rendered as a raster **hillshade** layer shaded from the DEM
/// (terrarium) source. This is GPU-friendly: it is a plain blended tile layer
/// that draws visible mountain relief under the tilted camera, unlike the
/// native 3D `terrain` mesh (a root style property) which builds a heavy 3D
/// geometry that renders the whole map BLACK on low-end Mali GPUs (the itel
/// P663LN) once the DEM mesh loads.
Map<String, dynamic> applyTerrainToStyle(
  Map<String, dynamic> baseStyle,
  Map<String, dynamic>? demSource, {
  required bool enabled,
  double exaggeration = 1.5,
}) {
  final style = jsonDecode(jsonEncode(baseStyle)) as Map<String, dynamic>;
  final src = style['sources'] as Map<String, dynamic>;
  final layers = style['layers'] as List<dynamic>;
  if (enabled && demSource != null) {
    src['terrain-dem'] = demSource;
    // Insert the relief right above the base layers (the `background` and any
    // `raster-fallback`) so it shades the land / raster, while the vector
    // roads/buildings/labels (higher layers) draw on top of it.
    var insertAt = 0;
    for (var i = 0; i < layers.length; i++) {
      final id = layers[i] is Map ? (layers[i] as Map)['id'] : null;
      if (id != 'background' && id != 'raster-fallback') {
        insertAt = i;
        break;
      }
    }
    layers.insert(insertAt, <String, dynamic>{
      'id': 'terrain-hillshade',
      'type': 'hillshade',
      'source': 'terrain-dem',
      'paint': <String, dynamic>{
        'hillshade-exaggeration': exaggeration * 1.6,
        'hillshade-shadow-color': 'rgba(0,0,0,0.6)',
        'hillshade-highlight-color': 'rgba(255,255,255,0.4)',
        'hillshade-accent-color': '#000000',
      },
    });
  } else {
    src.remove('terrain-dem');
    layers.removeWhere((l) => l is Map && l['id'] == 'terrain-hillshade');
  }
  return style;
}

// ---- store -------------------------------------------------------------

Future<File> _terrainTileFile(int z, int x, int y) async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/$kTerrainDir/$z/$x/$y.png');
}

/// Root of the downloaded terrarium store — used to build the `file://`
/// `raster-dem` source URL template for MapLibre.
Future<String> terrainTilesRoot() async {
  final sup = await getApplicationSupportDirectory();
  return '${sup.path}/$kTerrainDir';
}

/// True when any offline DEM data is present (a downloaded tile or the
/// bundled `terrain.pmtiles`). Used to enable/disable the 3D terrain toggle.
Future<bool> terrainAvailable() async {
  // Bundled pmtiles wins (see [terrainPmtilesPath]).
  final pm = await terrainPmtilesPath();
  if (pm != null) return true;
  final root = await terrainTilesRoot();
  final dir = Directory(root);
  if (!dir.existsSync()) return false;
  return dir
      .listSync(recursive: true)
      .any((f) => f is File && f.path.endsWith('.png'));
}

/// Absolute path of a bundled `terrain.pmtiles` (copied from assets into app
/// storage, like the vector map), or null when not bundled.
Future<String?> terrainPmtilesPath() async {
  final sup = await getApplicationSupportDirectory();
  final f = File('${sup.path}/nav_map/terrain.pmtiles');
  if (f.existsSync()) return f.path;
  // Try the bundled asset (Flutter asset:// can't be read by MapLibre on
  // Android, so copy it to storage like the nav map pmtiles).
  try {
    final data = await rootBundle.load('assets/offline_map/terrain.pmtiles');
    f.createSync(recursive: true);
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return f.path;
  } catch (_) {
    return null; // not bundled
  }
}

// ---- downloader --------------------------------------------------------

/// Downloads Terrarium DEM tiles for [bounds] with progress + cancel support.
/// Mirrors the map-tile [RegionDownloader]: single-threaded, rate-limited,
/// skips tiles already on disk, and only caches real PNGs.
class TerrainDownloader {
  TerrainDownloader(this.bounds);

  final LatLngBounds bounds;
  int done = 0;
  int failed = 0;
  bool blocked = false;
  bool _cancel = false;

  int get total {
    var n = 0;
    for (var z = kTerrainMinZoom; z <= kTerrainMaxZoom; z++) {
      n += _tileCount(bounds, z);
    }
    return n;
  }

  void cancel() => _cancel = true;

  Future<void> download(void Function(int done, int total) onProgress) async {
    done = 0;
    failed = 0;
    blocked = false;
    const minGap = Duration(milliseconds: 150); // ~6 tiles/s — gentle on S3
    var lastRequest = DateTime.now();
    for (var z = kTerrainMinZoom; z <= kTerrainMaxZoom; z++) {
      if (_cancel) return;
      final x0 = lonToTileX(bounds.west, z);
      final x1 = lonToTileX(bounds.east, z);
      final y0 = latToTileY(bounds.north, z);
      final y1 = latToTileY(bounds.south, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (_cancel) return;
          final f = await _terrainTileFile(z, x, y);
          if (f.existsSync()) {
            done++;
            continue;
          }
          final wait = minGap - DateTime.now().difference(lastRequest);
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
          }
          lastRequest = DateTime.now();
          try {
            final url = kTerrainTileUrl
                .replaceAll('{z}', '$z')
                .replaceAll('{x}', '$x')
                .replaceAll('{y}', '$y');
            final res = await http
                .get(Uri.parse(url), headers: const {'User-Agent': _ua})
                .timeout(const Duration(seconds: 12));
            if (res.statusCode == 429 || res.statusCode == 403) {
              blocked = true; // stop before we get blocked
              return;
            }
            if (res.statusCode == 200 &&
                res.bodyBytes.isNotEmpty &&
                _isPng(res.bodyBytes)) {
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

  int _tileCount(LatLngBounds b, int z) {
    final x0 = lonToTileX(b.west, z);
    final x1 = lonToTileX(b.east, z);
    final y0 = latToTileY(b.north, z);
    final y1 = latToTileY(b.south, z);
    return (x1 - x0 + 1) * (y1 - y0 + 1);
  }
}

// ---- elevation sampling ------------------------------------------------

/// Sample the terrain elevation (m) at [p] from the downloaded terrarium
/// tiles with bilinear interpolation, or null when no tile is on disk.
/// [zoom] is the DEM resolution to use (default 12 ≈ 76 m/px — plenty for a
/// route profile and much cheaper to have on disk than z13 everywhere).
Future<double?> elevationAt(LatLng p, {int zoom = 12}) async {
  final z = zoom.clamp(kTerrainMinZoom, kTerrainMaxZoom);
  final x = lonToTileX(p.longitude, z);
  final y = latToTileY(p.latitude, z);
  final f = await _terrainTileFile(z, x, y);
  if (!f.existsSync()) return null;
  try {
    final bytes = await f.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    if (img.width != 256 || img.height != 256) {
      img.dispose();
      return null;
    }
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) return null;

    // Sub-pixel position within the 256×256 tile.
    final n = math.pow(2, z).toDouble();
    final px = (((p.longitude + 180.0) / 360.0) * n) % 1.0;
    final latRad = p.latitude * math.pi / 180.0;
    final py =
        ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
            2.0 *
            n) %
        1.0;
    final fx = px * 255.0;
    final fy = py * 255.0;
    final x0 = fx.floor().clamp(0, 255);
    final y0 = fy.floor().clamp(0, 255);
    final x1i = (x0 + 1).clamp(0, 255);
    final y1i = (y0 + 1).clamp(0, 255);
    final tx = fx - x0;
    final ty = fy - y0;

    double pxAt(int xx, int yy) {
      final o = (yy * 256 + xx) * 4;
      return terrariumDecode(
        data.getUint8(o),
        data.getUint8(o + 1),
        data.getUint8(o + 2),
      );
    }

    final a = pxAt(x0, y0);
    final b = pxAt(x1i, y0);
    final c = pxAt(x0, y1i);
    final d = pxAt(x1i, y1i);
    final top = a + (b - a) * tx;
    final bot = c + (d - c) * tx;
    return top + (bot - top) * ty;
  } catch (_) {
    return null;
  }
}

/// Elevation profile of a route polyline: samples the offline DEM along the
/// route (~every [sampleMeters], capped at [maxSamples]) and returns the
/// total ascent/descent plus min/max and the sampled series for the chart.
/// Returns null when no offline DEM is available for the route.
class TerrainProfile {
  final double up; // meters climbed
  final double down; // meters descended
  final double minElev;
  final double maxElev;

  /// (distanceMeters, elevationMeters) samples along the route — feeds the
  /// elevation chart on the nav screen.
  final List<(double, double)> profile;
  const TerrainProfile({
    required this.up,
    required this.down,
    required this.minElev,
    required this.maxElev,
    required this.profile,
  });
}

Future<TerrainProfile?> routeTerrainProfile(
  List<LatLng> poly, {
  double sampleMeters = 120,
  int maxSamples = 80,
  int zoom = 12,
}) async {
  if (poly.length < 2) return null;
  // Sample along the polyline (cumulative meters) then interpolate points.
  final cum = <double>[];
  var c = 0.0;
  cum.add(0);
  for (var i = 1; i < poly.length; i++) {
    c += const Distance().as(LengthUnit.Meter, poly[i - 1], poly[i]);
    cum.add(c);
  }
  if (c <= 0) return null;
  final step = (c / (maxSamples - 1)).clamp(sampleMeters, c);

  // Async sampling of the interpolated points.
  final profile = <(double, double)>[];
  var up = 0.0, down = 0.0;
  double? prev;
  double? minE, maxE;
  var have = 0;
  for (var d = 0.0; d < c && have < maxSamples; d += step) {
    // Interpolate a route point at d.
    var p = poly.last;
    for (var i = 1; i < poly.length; i++) {
      if (cum[i] >= d) {
        final seg = cum[i] - cum[i - 1];
        final t = seg == 0 ? 0.0 : (d - cum[i - 1]) / seg;
        final a = poly[i - 1];
        final b = poly[i];
        p = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        break;
      }
    }
    final e = await elevationAt(p, zoom: zoom);
    if (e == null) continue;
    have++;
    profile.add((d, e));
    minE = minE == null ? e : math.min(minE, e);
    maxE = maxE == null ? e : math.max(maxE, e);
    if (prev != null) {
      final diff = e - prev;
      if (diff > 0) {
        up += diff;
      } else {
        down -= diff;
      }
    }
    prev = e;
  }
  if (have < 2 || minE == null || maxE == null) return null;
  return TerrainProfile(
    up: up,
    down: down,
    minElev: minE,
    maxElev: maxE,
    profile: profile,
  );
}
