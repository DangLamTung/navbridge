/// Offline point-of-interest index for Việt Nam — bundled as a single compact
/// JSON (`assets/offline_map/vietnam_pois.json`) generated from OpenStreetMap.
///
/// Unlike the online Overpass quick-search (`poi_search.dart`), this works
/// with NO network: ~20k popular POIs (ATM, gas, food, hotel, hospital, …)
/// across 25 categories, each with optional rich metadata (address, phone,
/// opening hours, description, wikipedia) for the info card.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'offline_loader.dart';

/// One offline POI with optional rich metadata (info card fields).
class OfflinePoi {
  final String name;
  final double lat;
  final double lng;

  /// Category key (see [offlinePoiCategories]).
  final String category;

  final String? address;
  final String? phone;
  final String? openingHours;
  final String? description;
  final String? wikipedia; // "xx:Title" or "wikidata:Q…"
  final String? website;

  const OfflinePoi({
    required this.name,
    required this.lat,
    required this.lng,
    required this.category,
    this.address,
    this.phone,
    this.openingHours,
    this.description,
    this.wikipedia,
    this.website,
  });

  LatLng get pos => LatLng(lat, lng);

  /// A sensible default subtitle for list rows.
  String get subtitle {
    final parts = <String>[?address, ?openingHours];
    return parts.join(' · ');
  }

  bool get hasInfo =>
      address != null ||
      phone != null ||
      openingHours != null ||
      description != null ||
      wikipedia != null ||
      website != null;

  factory OfflinePoi.fromJson(String key, Map<String, dynamic> j) => OfflinePoi(
    name: (j['n'] ?? '') as String,
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
    category: key,
    address: j['a'] as String?,
    phone: j['ph'] as String?,
    openingHours: j['oh'] as String?,
    description: j['d'] as String?,
    wikipedia: j['w'] as String?,
    website: j['ws'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'n': name,
    'lat': lat,
    'lng': lng,
    if (address != null) 'a': address,
    if (phone != null) 'ph': phone,
    if (openingHours != null) 'oh': openingHours,
    if (description != null) 'd': description,
    if (wikipedia != null) 'w': wikipedia,
    if (website != null) 'ws': website,
  };
}

/// One offline POI category (e.g. `atm` = "Cây ATM 🏧").
class OfflinePoiCategory {
  final String key;
  final String label;
  final String emoji;
  final List<OfflinePoi> items;

  const OfflinePoiCategory({
    required this.key,
    required this.label,
    required this.emoji,
    required this.items,
  });
}

final OfflineListLoader<OfflinePoiCategory> _categories =
    OfflineListLoader<OfflinePoiCategory>(_fetchCategories);

/// Load the bundled POI index once (idempotent, returns the cached result).
Future<List<OfflinePoiCategory>> loadOfflinePois() => _categories.load();

Future<List<OfflinePoiCategory>> _fetchCategories() async {
  final raw = await rootBundle.loadString(
    'assets/offline_map/vietnam_pois.json',
  );
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final e in data.entries)
      OfflinePoiCategory(
        key: e.key,
        label: (e.value['label'] ?? e.key) as String,
        emoji: (e.value['emoji'] ?? '📍') as String,
        items: [
          for (final it
              in (e.value['items'] as List? ?? const [])
                  .cast<Map<String, dynamic>>())
            OfflinePoi.fromJson(e.key, it),
        ],
      ),
  ];
}

/// All categories (each with its items). Sorted alphabetically for stable UI.
Future<List<OfflinePoiCategory>> offlinePoiCategories() async {
  final c = await loadOfflinePois();
  return [...c]..sort((a, b) => a.label.compareTo(b.label));
}

/// Look up one category by key.
Future<OfflinePoiCategory?> offlinePoiCategory(String key) async {
  for (final c in await loadOfflinePois()) {
    if (c.key == key) return c;
  }
  return null;
}

/// Case- and diacritic-insensitive name search across ALL offline POIs.
/// Ranked exact → startsWith → contains; returns up to [limit].
Future<List<OfflinePoi>> searchOfflinePois(String text, {int limit = 8}) async {
  final cats = await loadOfflinePois();
  final q = _removeDiacritics(text.trim().toLowerCase());
  if (q.isEmpty) return const [];
  final exact = <OfflinePoi>[];
  final starts = <OfflinePoi>[];
  final contains = <OfflinePoi>[];
  for (final c in cats) {
    for (final p in c.items) {
      final n = _removeDiacritics(p.name.toLowerCase());
      if (n == q) {
        exact.add(p);
      } else if (n.startsWith(q)) {
        starts.add(p);
      } else if (n.contains(q)) {
        contains.add(p);
      }
    }
  }
  return [...exact, ...starts, ...contains].take(limit).toList();
}

/// All POIs in one category, optionally sorted by distance from [near].
Future<List<OfflinePoi>> poisInCategory(
  String key, {
  LatLng? near,
  int limit = 50,
}) async {
  final cat = await offlinePoiCategory(key);
  if (cat == null) return const [];
  final items = [...cat.items];
  if (near != null) {
    const d = Distance();
    items.sort(
      (a, b) => d
          .as(LengthUnit.Meter, a.pos, near)
          .compareTo(d.as(LengthUnit.Meter, b.pos, near)),
    );
  }
  return items.take(limit).toList();
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
