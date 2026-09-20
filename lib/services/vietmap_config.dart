/// Vietmap configuration (API keys + endpoints) and the global data-source
/// switch ('osm' default / 'vietmap').
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

class VietmapConfig {
  /// Vietmap API key(s) — autocomplete / place / routing.
  ///
  /// Provided at BUILD TIME via --dart-define. NEVER put a real key in this
  /// file (the original committed key was exposed via git history and must be
  /// rotated in the Vietmap console). Multiple keys can be given as a
  /// comma-separated list (`VIETMAP_API_KEY=key1,key2`) — the app round-robins
  /// through them per request so quota is spread and one key hitting its daily
  /// limit doesn't kill search/routing.
  static const String apiKey = String.fromEnvironment('VIETMAP_API_KEY');

  static List<String> _keys = apiKey
      .split(',')
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList();
  static int _keyIdx = 0;

  /// Failed/quarantined keys mapped to their quarantine expiration time.
  static final Map<String, DateTime> _quarantinedKeys = {};

  /// Duration to quarantine a key when it returns 401/403/429.
  static const Duration quarantineDuration = Duration(minutes: 10);

  /// Mark a key as failed (e.g. rate limited, invalid, or quota exhausted).
  static void markKeyFailed(String key) {
    final k = key.trim();
    if (k.isEmpty) return;
    _quarantinedKeys[k] = DateTime.now().add(quarantineDuration);
  }

  /// Check whether [key] is currently in quarantine.
  static bool isKeyQuarantined(String key) {
    final exp = _quarantinedKeys[key.trim()];
    if (exp == null) return false;
    if (DateTime.now().isAfter(exp)) {
      _quarantinedKeys.remove(key.trim());
      return false;
    }
    return true;
  }

  /// Reset quarantine and round-robin state for testing.
  @visibleForTesting
  static void resetQuarantineForTesting() {
    _quarantinedKeys.clear();
    _keyIdx = 0;
  }

  /// Override keys for unit testing.
  @visibleForTesting
  static void setKeysForTesting(List<String>? testKeys) {
    _keys = (testKeys ?? apiKey.split(','))
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    _quarantinedKeys.clear();
    _keyIdx = 0;
  }

  /// Next Vietmap key (round-robin across active, non-quarantined keys).
  /// Falls back to regular round-robin if every key is quarantined.
  /// Empty when no key was provided.
  static String nextKey() {
    if (_keys.isEmpty) return '';
    final now = DateTime.now();
    _quarantinedKeys.removeWhere((_, until) => now.isAfter(until));

    for (var i = 0; i < _keys.length; i++) {
      final idx = (_keyIdx + i) % _keys.length;
      final candidate = _keys[idx];
      if (!_quarantinedKeys.containsKey(candidate)) {
        _keyIdx = (idx + 1) % _keys.length;
        return candidate;
      }
    }

    final k = _keys[_keyIdx % _keys.length];
    _keyIdx = (_keyIdx + 1) % _keys.length;
    return k;
  }


  /// Vietmap TILE key — map tiles / style (also --dart-define only).
  static const String tileKey = String.fromEnvironment('VIETMAP_TILE_KEY');

  /// Google Maps Geocoding API key — used for SEARCH when provided (far better
  /// Vietnamese geocoding than Nominatim). Requires the Geocoding API enabled
  /// + billing in Google Cloud Console. Empty = search falls back to
  /// Nominatim. Also --dart-define only: `--dart-define=GOOGLE_GEOCODE_KEY=...`.
  static const String googleApiKey = String.fromEnvironment(
    'GOOGLE_GEOCODE_KEY',
  );

  /// Google Places API key — used for AUTOCOMPLETE + place-details search
  /// when provided (the best Vietnamese house-number address search, e.g.
  /// "62 đường 30/4"). Requires the Places API enabled + billing in Google
  /// Cloud Console. Empty = search falls back to Vietmap / Photon. Also
  /// --dart-define only: `--dart-define=GOOGLE_PLACES_KEY=...`.
  static const String googlePlacesKey = String.fromEnvironment(
    'GOOGLE_PLACES_KEY',
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

/// Base URL the app downloads the offline GraphHopper routing graph (`.ghz`)
/// from. Empty = graph download disabled (a graph must be placed manually).
/// Set at build time via `--dart-define=GRAPH_URL=http://<host>/` — the file
/// is expected at `$GRAPH_URL/graph.ghz` (built with `tools/build_graph.sh`).
const String graphDownloadBaseUrl = String.fromEnvironment('GRAPH_URL');

/// Base URL the app auto-updates the offline point data (traffic cameras +
/// road signs) from. Empty = auto-update disabled (only the bundled assets are
/// used). Set at build time via `--dart-define=DATA_URL=http://<host>/`. The
/// server should publish:
///   `$DATA_URL/version.json`  → `{"cameras": "123", "signs": "456"}` (version
///                               strings, e.g. content hashes / timestamps)
///   `$DATA_URL/vietnam_cameras.json`
///   `$DATA_URL/vietnam_signs.json`
/// (same schema as `assets/offline_map/`). A plain `python3 -m http.server`
/// over the folder works.
const String dataUpdateBaseUrl = String.fromEnvironment('DATA_URL');

/// CARTO API key — used to authenticate CARTO basemap raster tile requests.
/// Provided at BUILD TIME via `--dart-define=CARTO_API_KEY=...`.
const String cartoApiKey = String.fromEnvironment('CARTO_API_KEY');

/// If [url] targets CARTO (`basemaps.cartocdn.com`) and [cartoApiKey] is set,
/// appends `?key=...` (or `&key=...`) to authenticate the request.
///
/// CARTO switched its basemap auth from `api_key` to `key` (2026); the old
/// `?api_key=` is ignored and returns an "API KEY REQUIRED" watermark tile.
String appendCartoApiKey(String url) {
  if (cartoApiKey.isEmpty ||
      !url.contains('basemaps.cartocdn.com') ||
      url.contains('key=')) {
    return url;
  }
  return url.contains('?')
      ? '$url&key=$cartoApiKey'
      : '$url?key=$cartoApiKey';
}
