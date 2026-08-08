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

  /// Google Maps Geocoding API key — used for SEARCH when provided (far better
  /// Vietnamese geocoding than Nominatim). Requires the Geocoding API enabled
  /// + billing in Google Cloud Console. Empty = search falls back to
  /// Nominatim. Also --dart-define only: `--dart-define=GOOGLE_GEOCODE_KEY=...`.
  static const String googleApiKey = String.fromEnvironment(
    'GOOGLE_GEOCODE_KEY',
  );

  static const String autocomplete =
      'https://maps.vietmap.vn/api/autocomplete/v4';
  static const String place = 'https://maps.vietmap.vn/api/place/v4';
  static const String route = 'https://maps.vietmap.vn/api/route/v4';

  /// Vietmap raster map tiles — the light/standard map style.
  static const String mapTiles =
      'https://maps.vietmap.vn/api/maps/raster/v3/{z}/{x}/{y}?apikey=$tileKey';

  /// Vietmap raster satellite tiles.
  static const String satelliteTiles =
      'https://maps.vietmap.vn/maps/tiles/st/{z}/{x}/{y}.png?apikey=$tileKey';

  /// True when real keys were provided at build time (--dart-define), i.e.
  /// the Vietmap search/routing/tiles can actually run.
  static bool get hasKeys => apiKey.isNotEmpty && tileKey.isNotEmpty;
}

/// Active map/routing data source: 'osm' (default, offline-capable, OSM
/// tiles + Nominatim + OSRM/offline graph) or 'vietmap' (fast Vietnamese
/// search + routing + live traffic — needs internet).
String dataSource = 'osm';

/// Base URL the app downloads the offline vector navigation map (PMTiles)
/// from. Empty = download disabled (only the bundled default map is used).
/// Set at build time via `--dart-define=NAVMAP_URL=http://<host>/` — e.g. serve
/// `navbridge/assets/offline_map/` with `python3 -m http.server` and use
/// `http://10.0.2.2:8080` from the emulator or the host's LAN IP from a phone.
const String navMapDownloadBaseUrl = String.fromEnvironment('NAVMAP_URL');
