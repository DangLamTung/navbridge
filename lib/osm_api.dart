/// OpenStreetMap (Nominatim) search client for the mobile app.
///
/// Replaces the Vietmap autocomplete/place calls (which burn API transactions)
/// with the free Nominatim API — no key needed.
///
/// Flow: search (typing) -> pick suggestion (already carries lat/lng) ->
///       buildRoute(waypoints: [current, dest]).
///
/// Nominatim usage policy: 1 req/s, must send a descriptive User-Agent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_tiles.dart' show forceOffline;
import 'vietmap_api.dart';
import 'vietmap_config.dart' show VietmapConfig, dataSource;

const _nominatimBase = 'https://nominatim.openstreetmap.org';

/// One OSM search result — already resolved to coordinates, so no second
/// "place" request is needed (saves the Vietmap place transaction entirely).
class OsmSuggestion {
  final String refId; // e.g. "way/12345678" (osm_type/osm_id)
  final String display; // full display name
  final double lat;
  final double lng;

  /// Where this suggestion came from: 'osm' (has coords), 'vietmap' (coords
  /// from a place lookup on selection) or 'google' (has coords).
  final String source;

  OsmSuggestion({
    required this.refId,
    required this.display,
    required this.lat,
    required this.lng,
    this.source = 'osm',
  });
}

const _ua = 'navbridge/1.0 (BLE portable navigation; OSM search)';

/// On-disk cache of recent results — used when the network is unavailable.
final Map<String, List<OsmSuggestion>> _searchCache = {};
bool _searchCacheLoaded = false;

Future<File> _searchCacheFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/search_cache.json');
}

Future<void> _loadSearchCache() async {
  if (_searchCacheLoaded) return;
  _searchCacheLoaded = true;
  try {
    final f = await _searchCacheFile();
    if (!f.existsSync()) return;
    final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    for (final e in data.entries) {
      final list = (e.value as List).cast<Map<String, dynamic>>();
      _searchCache[e.key] = [
        for (final s in list)
          OsmSuggestion(
            refId: (s['refId'] ?? '') as String,
            display: (s['display'] ?? '') as String,
            lat: ((s['lat'] ?? 0) as num).toDouble(),
            lng: ((s['lng'] ?? 0) as num).toDouble(),
            source: (s['source'] ?? 'osm') as String,
          ),
      ];
    }
  } catch (_) {}
}

Future<void> _saveSearchCache() async {
  try {
    final f = await _searchCacheFile();
    final data = <String, dynamic>{
      for (final e in _searchCache.entries)
        e.key: [
          for (final s in e.value)
            {
              'refId': s.refId,
              'display': s.display,
              'lat': s.lat,
              'lng': s.lng,
              'source': s.source,
            },
        ],
    };
    await f.writeAsString(jsonEncode(data), flush: true);
  } catch (_) {}
}

/// Search suggestions for a partial query (min ~2 chars).
/// Falls back to the local cache when the network is unavailable; in forced
/// offline mode only the local cache is used. With the Vietmap data source
/// active, uses Vietmap autocomplete (fast, VN-focused) instead of Nominatim.
Future<List<OsmSuggestion>> osmAutocomplete(
  String text, {
  int limit = 6,
  LatLng? focus,
}) async {
  await _loadSearchCache();
  final key = text.trim().toLowerCase();
  if (forceOffline) return _searchCache[key] ?? const [];

  // Google Maps geocoding — used as the primary search when a key is
  // configured (far better Vietnamese results than Nominatim).
  if (VietmapConfig.googleApiKey.isNotEmpty) {
    try {
      final g = await googleGeocode(text, limit: limit);
      if (g.isNotEmpty) {
        _searchCache[key] = g;
        unawaited(_saveSearchCache());
        return g;
      }
    } catch (_) {
      // fall through to Vietmap / Nominatim
    }
  }

  if (dataSource == 'vietmap') {
    try {
      final vm = await vietmapAutocomplete(text, focus: focus);
      final out = <OsmSuggestion>[
        for (final s in vm.take(limit))
          OsmSuggestion(
            refId: s.refId,
            display: s.display,
            lat: 0,
            lng: 0,
            source: 'vietmap',
          ),
      ];
      if (out.isNotEmpty) return out;
    } catch (_) {
      // fall through to Nominatim
    }
  }

  try {
    final url =
        '$_nominatimBase/search'
        '?format=jsonv2'
        '&addressdetails=0'
        '&limit=$limit'
        '&accept-language=vi'
        '&q=${Uri.encodeQueryComponent(text)}';
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('OSM search HTTP ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    final out = <OsmSuggestion>[];
    for (final e in data.cast<Map<String, dynamic>>()) {
      final lat = double.tryParse('${e['lat']}');
      final lng = double.tryParse('${e['lon']}');
      final name = (e['display_name'] ?? '') as String;
      if (lat == null || lng == null || name.isEmpty) continue;
      out.add(
        OsmSuggestion(
          refId: '${e['osm_type']}/${e['osm_id']}',
          display: name,
          lat: lat,
          lng: lng,
        ),
      );
    }
    _searchCache[key] = out;
    unawaited(_saveSearchCache());
    return out;
  } catch (_) {
    return _searchCache[key] ?? const [];
  }
}

/// Google Maps Geocoding API search (used when [VietmapConfig.googleApiKey]
/// is configured). Requires the Google Geocoding API enabled + billing.
Future<List<OsmSuggestion>> googleGeocode(String text, {int limit = 6}) async {
  final key = VietmapConfig.googleApiKey;
  if (key.isEmpty) return const [];
  final url =
      'https://maps.googleapis.com/maps/api/geocode/json'
      '?address=${Uri.encodeQueryComponent(text)}'
      '&language=vi'
      '&region=vn'
      '&key=$key';
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return const [];
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final results = (data['results'] as List? ?? []).cast<Map<String, dynamic>>();
  final out = <OsmSuggestion>[];
  for (final r in results.take(limit)) {
    final addr = (r['formatted_address'] ?? '') as String;
    final geometry = r['geometry'] as Map<String, dynamic>?;
    final loc = geometry?['location'] as Map<String, dynamic>?;
    if (addr.isEmpty || loc == null) continue;
    out.add(
      OsmSuggestion(
        refId: (r['place_id'] ?? '') as String,
        display: addr,
        lat: ((loc['lat'] ?? 0) as num).toDouble(),
        lng: ((loc['lng'] ?? 0) as num).toDouble(),
        source: 'google',
      ),
    );
  }
  return out;
}
