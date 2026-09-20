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

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'package:navbridge/services/offline_poi.dart';
import 'offline_tiles.dart' show forceOffline, geocodingProvider;
import 'package:navbridge/services/vietmap_api.dart';
import 'package:navbridge/services/api_notice.dart' show noteGoogleQuota;
import 'vietmap_config.dart' show VietmapConfig, dataSource;

const _nominatimBase = 'https://nominatim.openstreetmap.org';

/// Photon (Komoot) geocoding — free, no API key, faster and better
/// Vietnamese results than Nominatim. Used as the online primary search when
/// [geocodingProvider] isn't explicitly set to 'nominatim'.
const _photonBase = 'https://photon.komoot.io/api';

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

  /// Optional bundled offline POI (from `vietnam_pois.json`) — when set, the
  /// UI can show the wiki-style info card (address/phone/description/…).
  final OfflinePoi? poi;

  OsmSuggestion({
    required this.refId,
    required this.display,
    required this.lat,
    required this.lng,
    this.source = 'osm',
    this.poi,
  });
}

const _ua = 'navbridge/1.0 (BLE portable navigation; OSM search)';

/// On-disk cache of recent results — used when the network is unavailable.
final Map<String, List<OsmSuggestion>> _searchCache = {};
bool _searchCacheLoaded = false;
const int _maxSearchCacheEntries = 100;

void _cacheSearchResult(String key, List<OsmSuggestion> list) {
  _searchCache[key] = list;
  if (_searchCache.length > _maxSearchCacheEntries) {
    _searchCache.remove(_searchCache.keys.first);
  }
}

Future<File> _searchCacheFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/search_cache.json');
}

Future<void> _loadSearchCache() async {
  if (_searchCacheLoaded) return;
  _searchCacheLoaded = true;
  try {
    final f = await _searchCacheFile();
    if (!await f.exists()) return;
    final raw = await f.readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final entries = data.entries.toList();
    final keep = entries.length > _maxSearchCacheEntries
        ? entries.sublist(entries.length - _maxSearchCacheEntries)
        : entries;
    for (final e in keep) {
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

/// Bundled offline place index (cities / districts / landmarks of Việt Nam
/// with coordinates) — searched ON-DEVICE so geocoding works with no network.
List<OsmSuggestion>? _offlinePlaces;
bool _offlinePlacesLoaded = false;

Future<void> _loadOfflinePlaces() async {
  if (_offlinePlacesLoaded) return;
  _offlinePlacesLoaded = true;
  try {
    final raw = await rootBundle.loadString(
      'assets/offline_map/vietnam_places.json',
    );
    final list = jsonDecode(raw) as List;
    _offlinePlaces = [
      for (final e in list.cast<Map<String, dynamic>>())
        OsmSuggestion(
          refId: 'offline/${e['name']}',
          display: (e['name'] ?? '') as String,
          lat: ((e['lat'] ?? 0) as num).toDouble(),
          lng: ((e['lng'] ?? 0) as num).toDouble(),
          source: 'offline',
        ),
    ];
  } catch (_) {
    _offlinePlaces = const [];
  }
}

/// Case-insensitive substring match over the bundled offline place index.
Future<List<OsmSuggestion>> _offlineSearch(String text, int limit) async {
  await _loadOfflinePlaces();
  final places = _offlinePlaces ?? const <OsmSuggestion>[];
  // Match WITHOUT Vietnamese diacritics so "ha noi" finds "Hà Nội".
  final q = _removeDiacritics(text.trim().toLowerCase());
  if (q.isEmpty) return const [];
  // Rank: exact / starts-with first, then contains.
  final starts = <OsmSuggestion>[];
  final contains = <OsmSuggestion>[];
  for (final p in places) {
    final name = _removeDiacritics(p.display.toLowerCase());
    if (name == q) {
      starts.insert(0, p);
    } else if (name.startsWith(q)) {
      starts.add(p);
    } else if (name.contains(q)) {
      contains.add(p);
    }
  }
  return [...starts, ...contains].take(limit).toList();
}

/// Strips Vietnamese diacritics (tone marks + đ) so search works with or
/// without accents. Returns the input unchanged for non-Vietnamese text.
String _removeDiacritics(String s) {
  const map = {
    'à': 'a',
    'á': 'a',
    'ả': 'a',
    'ã': 'a',
    'ạ': 'a',
    'ă': 'a',
    'ằ': 'a',
    'ắ': 'a',
    'ẳ': 'a',
    'ẵ': 'a',
    'ặ': 'a',
    'â': 'a',
    'ầ': 'a',
    'ấ': 'a',
    'ẩ': 'a',
    'ẫ': 'a',
    'ậ': 'a',
    'è': 'e',
    'é': 'e',
    'ẻ': 'e',
    'ẽ': 'e',
    'ẹ': 'e',
    'ê': 'e',
    'ề': 'e',
    'ế': 'e',
    'ể': 'e',
    'ễ': 'e',
    'ệ': 'e',
    'ì': 'i',
    'í': 'i',
    'ỉ': 'i',
    'ĩ': 'i',
    'ị': 'i',
    'ò': 'o',
    'ó': 'o',
    'ỏ': 'o',
    'õ': 'o',
    'ọ': 'o',
    'ô': 'o',
    'ồ': 'o',
    'ố': 'o',
    'ổ': 'o',
    'ỗ': 'o',
    'ộ': 'o',
    'ơ': 'o',
    'ờ': 'o',
    'ớ': 'o',
    'ở': 'o',
    'ỡ': 'o',
    'ợ': 'o',
    'ù': 'u',
    'ú': 'u',
    'ủ': 'u',
    'ũ': 'u',
    'ụ': 'u',
    'ư': 'u',
    'ừ': 'u',
    'ứ': 'u',
    'ử': 'u',
    'ữ': 'u',
    'ự': 'u',
    'ỳ': 'y',
    'ý': 'y',
    'ỷ': 'y',
    'ỹ': 'y',
    'ỵ': 'y',
    'đ': 'd',
    'À': 'A',
    'Á': 'A',
    'Ả': 'A',
    'Ã': 'A',
    'Ạ': 'A',
    'Ă': 'A',
    'Ằ': 'A',
    'Ắ': 'A',
    'Ẳ': 'A',
    'Ẵ': 'A',
    'Ặ': 'A',
    'Â': 'A',
    'Ầ': 'A',
    'Ấ': 'A',
    'Ẩ': 'A',
    'Ẫ': 'A',
    'Ậ': 'A',
    'È': 'E',
    'É': 'E',
    'Ẻ': 'E',
    'Ẽ': 'E',
    'Ẹ': 'E',
    'Ê': 'E',
    'Ề': 'E',
    'Ế': 'E',
    'Ể': 'E',
    'Ễ': 'E',
    'Ệ': 'E',
    'Ì': 'I',
    'Í': 'I',
    'Ỉ': 'I',
    'Ĩ': 'I',
    'Ị': 'I',
    'Ò': 'O',
    'Ó': 'O',
    'Ỏ': 'O',
    'Õ': 'O',
    'Ọ': 'O',
    'Ô': 'O',
    'Ồ': 'O',
    'Ố': 'O',
    'Ổ': 'O',
    'Ỗ': 'O',
    'Ộ': 'O',
    'Ơ': 'O',
    'Ờ': 'O',
    'Ớ': 'O',
    'Ở': 'O',
    'Ỡ': 'O',
    'Ợ': 'O',
    'Ù': 'U',
    'Ú': 'U',
    'Ủ': 'U',
    'Ũ': 'U',
    'Ụ': 'U',
    'Ư': 'U',
    'Ừ': 'U',
    'Ứ': 'U',
    'Ử': 'U',
    'Ữ': 'U',
    'Ự': 'U',
    'Ỳ': 'Y',
    'Ý': 'Y',
    'Ỷ': 'Y',
    'Ỹ': 'Y',
    'Ỵ': 'Y',
    'Đ': 'D',
  };
  final b = StringBuffer();
  for (final ch in s.split('')) {
    b.write(map[ch] ?? ch);
  }
  return b.toString();
}

/// Whitelist of prominent Vietnamese historical dates used as street names:
/// 30/4 (Giải phóng miền Nam), 1/5 (Quốc tế Lao động), 19/5 (Sinh nhật Bác),
/// 2/9 (Quốc khánh), 3/2 (Thành lập Đảng), 26/3 (Thành lập Đoàn),
/// 23/9 (Nam Bộ kháng chiến), 8/3 (Quốc tế Phụ nữ), 20/10 (Phụ nữ VN),
/// 20/11 (Nhà giáo VN), 27/7 (Thương binh Liệt sĩ), 22/12 (Quân đội ND),
/// 19/8 (Cách mạng Tháng Tám), 10/3 (Giỗ tổ Hùng Vương).
const _historicalDateStreets = <(int, int)>{
  (30, 4),
  (1, 5),
  (19, 5),
  (2, 9),
  (3, 2),
  (26, 3),
  (23, 9),
  (8, 3),
  (20, 10),
  (20, 11),
  (27, 7),
  (22, 12),
  (19, 8),
  (10, 3),
};

/// Rewrite Vietnamese date-street shorthand ("Đường 30/4", "30-4", "30.4")
/// into the form OSM actually names it ("Đường 30 Tháng 4").
///
/// Protection against mangling house/alley numbers:
/// - If preceded by an alley/house indicator (hẻm, ngõ, ngách, kiệt, số) -> NOT rewritten.
/// - If preceded by a street indicator (đường, phố, đ., ql) -> any valid day/month (≤31/≤12) is rewritten.
/// - If standalone / no street indicator -> ONLY matches the historical date street whitelist
///   (so "15/4 Lê Lợi" stays an alley address and is NOT mangled into "15 Tháng 4 Lê Lợi").
/// Returns null when there is nothing to rewrite.
String? rewriteDateStreet(String s) {
  final m = RegExp(
    r'(?<![0-9])([0-9]{1,2})[/.\-]([0-9]{1,2})(?![0-9/.\-])',
  ).firstMatch(s);
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  if (d < 1 || d > 31 || mo < 1 || mo > 12) return null;

  final prefix = s.substring(0, m.start).trim().toLowerCase();
  // 1. Preceded by an alley or house number keyword -> keep as-is (not a date street)
  final isAlley = RegExp(
    r'(?:hẻm|hem|ngõ|ngo|ngách|ngach|kiệt|kiet|số|so)\s*$',
    caseSensitive: false,
  ).hasMatch(prefix);
  if (isAlley) return null;

  // 2. Preceded by a street keyword -> rewrite
  final isStreet = RegExp(
    r'(?:đường|duong|đ\.|d\.|phố|pho|đoạn|doan|quốc lộ|quoc lo|ql)\s*$',
    caseSensitive: false,
  ).hasMatch(prefix);
  if (isStreet) {
    return s.replaceFirst(m.group(0)!, '${m.group(1)} Tháng ${m.group(2)}');
  }

  // 3. No street keyword -> only rewrite if it matches the Vietnamese historical date street whitelist
  if (_historicalDateStreets.contains((d, mo))) {
    return s.replaceFirst(m.group(0)!, '${m.group(1)} Tháng ${m.group(2)}');
  }

  return null;
}

/// Split a leading Vietnamese house number from the street part of an
/// address. Handles "62", "62A", "62/8", "62/8A":
///   splitHouseNumber("62 đường 30/4") → ("62", "đường 30/4")
///
/// Prevents misinterpreting date streets as house numbers:
///   "30/4 Tân Bình" → null (it's the 30/4 street in Tân Bình, not house 30/4 on Tân Bình street).
/// Returns null when there is no leading house number.
(String, String)? splitHouseNumber(String s) {
  final m = RegExp(
    r'^[0-9]+[A-Za-z]?(?:/[0-9]+[A-Za-z]?)?\s+',
  ).matchAsPrefix(s);
  if (m == null) return null;

  final numPart = m.group(0)!.trim();
  final rest = s.substring(m.end).trim();

  // If numPart looks like a date (e.g. 30/4, 2/9) and is in the historical
  // date-street whitelist, check whether the query is actually a date-street
  // name rather than a house number on another street.
  final dateMatch = RegExp(r'^([0-9]{1,2})[/.\-]([0-9]{1,2})$').firstMatch(numPart);
  if (dateMatch != null) {
    final d = int.parse(dateMatch.group(1)!);
    final mo = int.parse(dateMatch.group(2)!);
    if (_historicalDateStreets.contains((d, mo))) {
      final lowerRest = rest.toLowerCase();
      final hasStreetKeyword = RegExp(
        r'^(?:đường|duong|phố|pho|đ\.|d\.)\b',
      ).hasMatch(lowerRest);
      final isDistrictOrCityOrPunct = RegExp(
        r'^(?:p\.|phường|phuong|q\.|quận|quan|h\.|huyện|huyen|tx\.|thị xã|thi xa|tp\.|thành phố|thanh pho|tỉnh|tinh|,)\b',
      ).hasMatch(lowerRest);

      // If followed by an area/city/comma OR not followed by an explicit street keyword,
      // treat the date as the street name itself, not a house number.
      if (isDistrictOrCityOrPunct || !hasStreetKeyword) {
        return null;
      }
    }
  }

  return (numPart, rest);
}

/// Photon (Komoot) search. Photon returns GeoJSON features without a ready
/// display_name, so a human label is assembled from its address parts.
/// Location-biases toward [focus] (the phone's GPS) so a street that exists
/// in several cities ("Đường 30 Tháng 4" is in Tân Phú AND Thủ Dầu Một…)
/// resolves to the nearby one.
///
/// A single query can miss a house number ("62 đường 30/4" — the "/" token
/// and the number confuse Photon), so variants are tried and merged:
///   1. the VN date-street rewrite of the FULL query ("30/4" → "30 Tháng 4",
///      the form OSM actually names it — resolves far better, put first),
///   2. the query as typed,
///   3. when a leading house number is present ("62", "62A", "62/8"), the
///      BARE STREET alone (rewritten, then as typed) — this is what actually
///      resolves "62 đường 30/4" to "Đường 30 Tháng 4".
Future<List<OsmSuggestion>> _photonSearch(
  String text, {
  int limit = 6,
  LatLng? focus,
}) async {
  final original = text.trim();
  // Split a leading Vietnamese house number ("62", "62A", "62/8", "62/8A")
  // from the street so the street part can be searched on its own.
  final split = splitHouseNumber(original);
  final house = split?.$1;
  final street = split?.$2 ?? '';

  final out = <OsmSuggestion>[];
  // 1) Full-query variants run in PARALLEL (date-street rewrite + as typed).
  final fullVariants = <String>[];
  final fullRewritten = rewriteDateStreet(original);
  if (fullRewritten != null) fullVariants.add(fullRewritten);
  if (!fullVariants.contains(original)) fullVariants.add(original);

  final fullResults = await Future.wait([
    for (final v in fullVariants)
      _photonSearchRaw(v, limit: limit, focus: focus).catchError(
        (_) => <OsmSuggestion>[],
      ),
  ]);
  for (final res in fullResults) {
    out.addAll(res);
  }

  // 2) House-number query with no hits → bare street (rewritten, then typed).
  if (out.isEmpty && house != null && street.isNotEmpty) {
    final streetVariants = <String>[];
    final streetRewritten = rewriteDateStreet(street);
    if (streetRewritten != null) streetVariants.add(streetRewritten);
    if (!streetVariants.contains(street)) streetVariants.add(street);

    final streetResults = await Future.wait([
      for (final v in streetVariants)
        _photonSearchRaw(v, limit: limit, focus: focus).catchError(
          (_) => <OsmSuggestion>[],
        ),
    ]);
    for (final res in streetResults) {
      out.addAll(res);
    }
  }
  // De-duplicate by OSM ref (Photon repeats some features).
  final seen = <String>{};
  return [
    for (final s in out)
      if (seen.add(s.refId)) s,
  ].take(limit).toList();
}


/// One Photon query. NOTE: no `lang=` param — Photon only supports
/// default/de/en/fr and REJECTS the whole request for any other language
/// (e.g. `lang=vi` returns an error body and zero results, silently breaking
/// every search).
Future<List<OsmSuggestion>> _photonSearchRaw(
  String text, {
  int limit = 6,
  LatLng? focus,
}) async {
  final bias = focus == null
      ? ''
      : '&lat=${focus.latitude}&lon=${focus.longitude}';
  final url =
      '$_photonBase'
      '?q=${Uri.encodeQueryComponent(text)}'
      '&limit=$limit'
      '&countrycode=vn'
      '$bias';
  final res = await http
      .get(Uri.parse(url), headers: {'User-Agent': _ua})
      .timeout(const Duration(seconds: 8));
  if (res.statusCode != 200) {
    throw Exception('Photon HTTP ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final features = (data['features'] as List? ?? [])
      .cast<Map<String, dynamic>>();
  final out = <OsmSuggestion>[];
  for (final f in features) {
    final geo = f['geometry'] as Map<String, dynamic>?;
    final coords = (geo?['coordinates'] as List?)?.cast<num>();
    if (coords == null || coords.length < 2) continue;
    final props = f['properties'] as Map<String, dynamic>? ?? {};
    final name = (props['name'] ?? '') as String;
    if (name.isEmpty) continue;
    final addr = (props['osm_value'] ?? '') as String;
    final district = (props['district'] ?? '') as String;
    final city = (props['city'] ?? '') as String;
    final state = (props['state'] ?? '') as String;
    final display = <String>[
      name,
      if (addr.isNotEmpty && addr != name) addr,
      if (district.isNotEmpty) district,
      if (city.isNotEmpty) city,
      if (state.isNotEmpty) state,
    ].join(', ');
    final osmType = (props['osm_type'] ?? 'relation') as String;
    final id = props['osm_id'];
    out.add(
      OsmSuggestion(
        refId: '$osmType/${id ?? '${coords[1]},${coords[0]}'}',
        display: display,
        lat: coords[1].toDouble(),
        lng: coords[0].toDouble(),
      ),
    );
  }
  return out;
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
  // Offline: the bundled Việt Nam place index + previously cached results +
  // the bundled POI index (ATM/gas/food/…) — so geocoding works with NO
  // network (no more empty offline search).
  if (forceOffline) {
    final bundled = await _offlineSearch(text, limit);
    final cached = _searchCache[key] ?? const <OsmSuggestion>[];
    final pois = (await searchOfflinePois(text, limit: limit)).map(
      (p) => OsmSuggestion(
        refId: 'poi/${p.category}/${p.name}',
        display: p.name,
        lat: p.lat,
        lng: p.lng,
        source: 'poi',
        poi: p,
      ),
    );
    final out = [...bundled, ...cached, ...pois];
    // De-duplicate by (lat,lng) — POIs first so they win over place entries.
    final seen = <String>{};
    return _sortNearFocus(
      [
        for (final s in out)
          if (seen.add('${s.lat},${s.lng}')) s,
      ].take(limit).toList(),
      focus,
      query: text,
    );
  }

  // Google Places AUTOCOMPLETE — the best type-ahead for Vietnamese
  // house-number addresses ("62 đường 30/4"). Used first when a Places key is
  // configured; suggestions carry only a place_id (coordinates are resolved
  // on selection via googlePlaceDetails).
  if (VietmapConfig.googlePlacesKey.isNotEmpty) {
    try {
      final g = await googlePlaceAutocomplete(text, limit: limit, focus: focus);
      if (g.isNotEmpty) {
        _cacheSearchResult(key, g);
        unawaited(_saveSearchCache());
        return _sortNearFocus(g, focus, query: text);
      }
    } catch (_) {
      // fall through to Vietmap / Nominatim
    }
  }

  // Google Maps geocoding — full-address search when a key is configured (far
  // better Vietnamese results than Nominatim).
  if (VietmapConfig.googleApiKey.isNotEmpty) {
    try {
      final g = await googleGeocode(text, limit: limit);
      if (g.isNotEmpty) {
        _cacheSearchResult(key, g);
        unawaited(_saveSearchCache());
        return _sortNearFocus(g, focus, query: text);
      }
    } catch (_) {
      // fall through to Vietmap / Nominatim
    }
  }

  // Vietmap autocomplete — fast, VN-focused. Used when the user picked
  // Vietmap as the geocoding provider, OR implicitly by the Vietmap data
  // source. (On the OSM data source a chosen Vietmap provider still resolves
  // coordinates via a place call on selection.)
  if (geocodingProvider == 'vietmap' || dataSource == 'vietmap') {
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
      if (out.isNotEmpty) return _sortNearFocus(out, focus, query: text);
    } catch (_) {
      // fall through to Nominatim
    }
  }

  // Photon (Komoot) — free, no key, faster + better Vietnamese results than
  // Nominatim. Default provider; Nominatim is the fallback below.
  if (geocodingProvider != 'nominatim') {
    try {
      final out = await _photonSearch(text, limit: limit, focus: focus);
      if (out.isNotEmpty) {
        _cacheSearchResult(key, out);
        unawaited(_saveSearchCache());
        return _sortNearFocus(out, focus, query: text);
      }
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
        '&countrycodes=vn'
        '&q=${Uri.encodeQueryComponent(text)}';
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 8));
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
    _cacheSearchResult(key, out);
    unawaited(_saveSearchCache());
    return _sortNearFocus(out, focus, query: text);
  } catch (_) {
    // Online search failed / empty — fall back to the bundled offline place
    // index so geocoding still works even with a dead network.
    final bundled = await _offlineSearch(text, limit);
    final cached = _searchCache[key] ?? const <OsmSuggestion>[];
    final pois = (await searchOfflinePois(text, limit: limit)).map(
      (p) => OsmSuggestion(
        refId: 'poi/${p.category}/${p.name}',
        display: p.name,
        lat: p.lat,
        lng: p.lng,
        source: 'poi',
        poi: p,
      ),
    );
    final out = [...bundled, ...cached, ...pois];
    final seen = <String>{};
    return _sortNearFocus(
      [
        for (final s in out)
          if (seen.add('${s.lat},${s.lng}')) s,
      ].take(limit).toList(),
      focus,
      query: text,
    );
  }
}

/// Sort [suggestions] balancing search engine relevance and proximity to
/// [focus] (current location).
///
/// If [query] is provided and the top search result is an exact/prominent
/// match (e.g. searching "Hà Nội" yields "Thành phố Hà Nội"), it is preserved
/// at rank 1 rather than being pushed below a local shop 1000 km closer.
///
/// Suggestions with unresolved coordinates (`lat==0 && lng==0`) retain their
/// relative order after resolved suggestions.
List<OsmSuggestion> _sortNearFocus(
  List<OsmSuggestion> suggestions,
  LatLng? focus, {
  String? query,
}) {
  if (focus == null || suggestions.length < 2) return suggestions;
  const Distance d = Distance();
  final q = query != null ? _removeDiacritics(query.trim().toLowerCase()) : '';

  double score(int originalIndex, OsmSuggestion s) {
    if (s.lat == 0 && s.lng == 0) {
      return 1e9 + originalIndex;
    }
    final distKm = d.as(LengthUnit.Meter, focus, LatLng(s.lat, s.lng)) / 1000.0;
    final name = _removeDiacritics(s.display.toLowerCase());

    final isExact = q.isNotEmpty &&
        (name == q ||
            name.startsWith('$q,') ||
            name.startsWith('thanh pho $q') ||
            name.startsWith('tp. $q') ||
            name.startsWith('tp $q'));
    final startsWith = q.isNotEmpty && name.startsWith(q);

    // If the top search result is an exact or prominent text match, keep it at the top
    if (originalIndex == 0 && (isExact || startsWith)) {
      return -1000.0;
    }

    // Weight distance and original search engine relevance
    double penalty = distKm;
    if (isExact) {
      penalty *= 0.1;
    } else if (startsWith) {
      penalty *= 0.4;
    }
    // Search engine rank penalty (15 km per rank)
    penalty += originalIndex * 15.0;

    return penalty;
  }

  final indexed = suggestions.asMap().entries.toList();
  indexed.sort((a, b) => score(a.key, a.value).compareTo(score(b.key, b.value)));
  return indexed.map((e) => e.value).toList();
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

/// Google Places AUTOCOMPLETE — true type-ahead search, and the best online
/// option for Vietnamese house-number addresses ("62 đường 30/4"). Each
/// prediction carries only a place_id ([OsmSuggestion.refId]); coordinates
/// are resolved on selection via [googlePlaceDetails]. Returns [] when no
/// key / no results / request failed.
Future<List<OsmSuggestion>> googlePlaceAutocomplete(
  String text, {
  int limit = 6,
  LatLng? focus,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) return const [];
  var url =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json'
      '?input=${Uri.encodeQueryComponent(text)}'
      '&components=country:vn'
      '&language=vi'
      '&key=$key';
  if (focus != null) {
    // Bias suggestions toward the phone (~50 km circle) so a street that
    // exists in several cities resolves to the nearby one.
    url += '&locationbias=circle:50000@${focus.latitude},${focus.longitude}';
  }
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    noteGoogleQuota(statusCode: res.statusCode, body: res.body);
    return const [];
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  if (data['status'] != 'OK') {
    noteGoogleQuota(
      statusCode: res.statusCode,
      status: data['status'] as String?,
    );
    return const [];
  }
  final out = <OsmSuggestion>[];
  for (final r
      in (data['predictions'] as List? ?? []).cast<Map<String, dynamic>>().take(
        limit,
      )) {
    final desc = (r['description'] ?? '') as String;
    if (desc.isEmpty) continue;
    out.add(
      OsmSuggestion(
        refId: (r['place_id'] ?? '') as String,
        display: desc,
        lat: 0,
        lng: 0,
        source: 'google',
      ),
    );
  }
  return out;
}

/// Resolve a Google Places autocomplete prediction ([place_id]) to
/// coordinates + a formatted address. One transaction per call (only fired
/// when the user picks a suggestion). Returns (lat, lng, display) or null.
Future<(double, double, String)?> googlePlaceDetails(String placeId) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) return null;
  final url =
      'https://maps.googleapis.com/maps/api/place/details/json'
      '?place_id=${Uri.encodeQueryComponent(placeId)}'
      '&fields=geometry,formatted_address'
      '&language=vi'
      '&key=$key';
  final res = await http
      .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    noteGoogleQuota(statusCode: res.statusCode, body: res.body);
    return null;
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  if (data['status'] != 'OK') {
    noteGoogleQuota(
      statusCode: res.statusCode,
      status: data['status'] as String?,
    );
    return null;
  }
  final result = data['result'] as Map<String, dynamic>?;
  if (result == null) return null;
  final loc = result['geometry']?['location'] as Map<String, dynamic>?;
  final lat = (loc?['lat'] as num?)?.toDouble();
  final lng = (loc?['lng'] as num?)?.toDouble();
  if (lat == null || lng == null) return null;
  final display = (result['formatted_address'] ?? '') as String;
  return (lat, lng, display);
}

/// Google Places TEXT SEARCH — find REAL POIs (gas, food, hotel…) near
/// [center]. Requires the Places API (Text Search) enabled + billing.
/// Returns (name, lat, lng) tuples, empty on failure. Used to ground the AI
/// assistant's "tìm xăng / nhà hàng gần đây" answers in real, current data
/// instead of letting the LLM invent coordinates.
Future<List<(String, double, double)>> googlePlaceTextSearch(
  String query,
  LatLng center, {
  int radius = 5000,
  int limit = 6,
}) async {
  final key = VietmapConfig.googlePlacesKey;
  if (key.isEmpty) return const [];
  final url =
      'https://maps.googleapis.com/maps/api/place/textsearch/json'
      '?query=${Uri.encodeQueryComponent(query)}'
      '&location=${center.latitude},${center.longitude}'
      '&radius=$radius'
      '&language=vi'
      '&key=$key';
  try {
    final res = await http
        .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      noteGoogleQuota(statusCode: res.statusCode, body: res.body);
      return const [];
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (data['status'] != 'OK') {
      noteGoogleQuota(
        statusCode: res.statusCode,
        status: data['status'] as String?,
      );
      return const [];
    }
    final results = (data['results'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final out = <(String, double, double)>[];
    for (final r in results.take(limit)) {
      final name = (r['name'] ?? '') as String;
      final geometry = r['geometry'] as Map<String, dynamic>?;
      final loc = geometry?['location'] as Map<String, dynamic>?;
      if (name.isEmpty || loc == null) continue;
      out.add((
        name,
        ((loc['lat'] ?? 0) as num).toDouble(),
        ((loc['lng'] ?? 0) as num).toDouble(),
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Reverse geocode coordinates to a human-readable address or road name.
/// Tries Google Geocoding (if key configured) -> Nominatim -> nearest offline POI/place.
/// Never throws; returns a clean address or formatted coordinates string.
Future<String> reverseGeocode(LatLng pos) async {
  // 1. Google Geocoding API (if key available)
  if (VietmapConfig.googleApiKey.isNotEmpty) {
    try {
      final key = VietmapConfig.googleApiKey;
      final url =
          'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${pos.latitude},${pos.longitude}'
          '&language=vi'
          '&key=$key';
      final res = await http
          .get(Uri.parse(url), headers: const {'User-Agent': 'navbridge/1.0'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final results = (data['results'] as List? ?? []).cast<Map<String, dynamic>>();
        if (results.isNotEmpty) {
          final addr = results[0]['formatted_address'] as String?;
          if (addr != null && addr.isNotEmpty) return addr;
        }
      }
    } catch (_) {}
  }

  // 2. Nominatim Reverse Geocoding (free OSM)
  if (!forceOffline) {
    try {
      final url =
          '$_nominatimBase/reverse'
          '?format=jsonv2'
          '&lat=${pos.latitude}&lon=${pos.longitude}'
          '&accept-language=vi';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final name = (data['display_name'] ?? '') as String;
        if (name.isNotEmpty) return name;
      }
    } catch (_) {}
  }

  // 3. Bundled offline places / POIs
  try {
    await _loadOfflinePlaces();
    const Distance d = Distance();
    OsmSuggestion? closest;
    double bestDist = 1000.0; // within 1km
    for (final p in _offlinePlaces ?? const <OsmSuggestion>[]) {
      final dist = d.as(LengthUnit.Meter, pos, LatLng(p.lat, p.lng));
      if (dist < bestDist) {
        bestDist = dist;
        closest = p;
      }
    }
    if (closest != null) {
      return '${closest.display} (~${bestDist.round()}m)';
    }
  } catch (_) {}

  // 4. Fallback to coordinates
  return '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
}
