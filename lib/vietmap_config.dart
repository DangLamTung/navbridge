/// Vietmap configuration (API keys + endpoints) and the global data-source
/// switch ('osm' default / 'vietmap').
library;

class VietmapConfig {
  /// Vietmap API key — autocomplete / place / routing (NOT tiles).
  static const String apiKey = String.fromEnvironment(
      'VIETMAP_API_KEY',
      defaultValue: 'REDACTED_VIETMAP_API_KEY');

  /// Vietmap TILE key — map tiles / style.
  static const String tileKey = String.fromEnvironment(
      'VIETMAP_TILE_KEY',
      defaultValue: 'REDACTED_VIETMAP_TILE_KEY');

  static const String autocomplete =
      'https://maps.vietmap.vn/api/autocomplete/v4';
  static const String place = 'https://maps.vietmap.vn/api/place/v4';
  static const String route = 'https://maps.vietmap.vn/api/route/v4';

  /// Raster satellite tiles (the only raster Vietmap style).
  static const String satelliteTiles =
      'https://maps.vietmap.vn/maps/tiles/st/{z}/{x}/{y}.png?apikey=$tileKey';
}

/// Active map/routing data source: 'osm' (default, offline-capable, OSM
/// tiles + Nominatim + OSRM/offline graph) or 'vietmap' (fast Vietnamese
/// search + routing + live traffic — needs internet).
String dataSource = 'osm';
