/// Zoom range + coverage box of a PMTiles archive, read from the file itself.
///
/// The nav map ships ONE vector archive and the app must know two things about
/// it: which zooms it holds and where it holds them.
///
/// Both are read from the header, which is authoritative — verified against the
/// reference `pmtiles` reader:
///
/// | archive | header | actual tiles |
/// |---|---|---|
/// | `assets/offline_map/saigon_z16.pmtiles` | z0-16 | data at z0-z16, nothing at z17+ |
/// | `tools/data/saigon.pmtiles` | z0-14 | data at z0-z14, nothing at z15+ |
///
/// Why the app needs it:
/// * the nav camera sits at z19 (`VectorNavMap.defaultZoom`) and can pinch to
///   z19, i.e. ABOVE the archive's max zoom. The style declared no min/max zoom
///   on its source, so MapLibre requested z17-z19 tiles that do not exist, the
///   vector layers drew nothing, and only the raster basemap below them was left
///   on screen (white / upscaled when offline or slow). Declaring the real range
///   makes MapLibre OVERZOOM the z16 tiles instead.
/// * the coverage box was hard-coded wider than the archive (10.40-11.20 /
///   106.30-107.10 vs the real 10.6564-10.8931 / 106.5444-106.8545), so in the
///   ring between them the app kept the vector style — with no tiles — instead
///   of switching to the raster fallback.
///
/// (A first version of this class decoded the tile directory instead; that parse
/// was wrong and reported z0-z11 for a z0-z16 file. The header is sufficient.)
library;

import 'dart:io';

/// Read-only facts about a PMTiles v3 archive.
class NavMapInfo {
  const NavMapInfo({
    required this.minZoom,
    required this.maxZoom,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    required this.tiles,
  });

  /// Lowest zoom with tiles in the archive.
  final int minZoom;

  /// Highest zoom with tiles in the archive — above this the renderer must
  /// overzoom; below it there is nothing to draw.
  final int maxZoom;

  final double minLat, maxLat, minLon, maxLon;

  /// Addressed tiles in the archive (0 when the header could not be read).
  final int tiles;

  /// True when [lat]/[lon] falls inside the archive's own bbox.
  bool contains(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  @override
  String toString() =>
      'NavMapInfo(z$minZoom-z$maxZoom, $tiles tiles, '
      '${minLat.toStringAsFixed(4)},${minLon.toStringAsFixed(4)} -> '
      '${maxLat.toStringAsFixed(4)},${maxLon.toStringAsFixed(4)})';

  /// Read [file]; null when it is missing or is not a PMTiles v3 archive.
  static Future<NavMapInfo?> read(File file) async {
    try {
      if (!file.existsSync()) return null;
      final raf = await file.open();
      try {
        final h = await raf.read(127);
        if (h.length < 127) return null;
        if (String.fromCharCodes(h.sublist(0, 7)) != 'PMTiles') return null;
        if (h[7] != 3) return null; // only the v3 header layout is parsed

        int u64(int at) {
          var v = 0;
          for (var i = 7; i >= 0; i--) {
            v = (v << 8) | h[at + i];
          }
          return v;
        }

        int i32(int at) {
          final v =
              h[at] | (h[at + 1] << 8) | (h[at + 2] << 16) | (h[at + 3] << 24);
          return (v & 0x80000000) != 0 ? v - 0x100000000 : v;
        }

        return NavMapInfo(
          minZoom: h[100],
          maxZoom: h[101],
          minLon: i32(102) / 1e7,
          minLat: i32(106) / 1e7,
          maxLon: i32(110) / 1e7,
          maxLat: i32(114) / 1e7,
          tiles: u64(72),
        );
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}
