/// Vietmap configuration (API keys + endpoints) and the global data-source
/// switch ('osm' default / 'vietmap').
library;

class VietmapConfig {
  /// Vietmap API key — autocomplete / place / routing.
  ///
  /// Provided at BUILD TIME via --dart-define. NEVER put a real key in this
  /// file (the original committed key was exposed via git history and must be
  /// rotated in the Vietmap console).
  static const String apiKey = String.fromEnvironment('VIETMAP_API_KEY');

  /// Vietmap TILE key — map tiles / style (also --dart-define only).
  static const String tileKey = String.fromEnvironment('VIETMAP_TILE_KEY');

  static const String autocomplete =
      'https://maps.vietmap.vn/api/autocomplete/v4';
  static const String place = 'https://maps.vietmap.vn/api/place/v4';
  static const String route = 'https://maps.vietmap.vn/api/route/v4';

  /// Raster satellite tiles (the only raster Vietmap style).
  static const String satelliteTiles =
      'https://maps.vietmap.vn/maps/tiles/st/{z}/{x}/{y}.png?apikey=$tileKey';

  /// Vietmap vector map style (tm = street) — used by the navigation SDK.
  static String get vectorStyle =>
      'https://maps.vietmap.vn/maps/styles/tm/style.json?apikey=$tileKey';

  /// True when real keys were provided at build time (--dart-define), i.e.
  /// the Vietmap features (and their navigation SDK) can actually run.
  static bool get hasKeys => apiKey.isNotEmpty && tileKey.isNotEmpty;
}

/// Active map/routing data source: 'osm' (default, offline-capable, OSM
/// tiles + Nominatim + OSRM/offline graph) or 'vietmap' (fast Vietnamese
/// search + routing + live traffic — needs internet).
String dataSource = 'osm';
