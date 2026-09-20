/// Recent search history ("Tìm kiếm gần đây") — the places searched before,
/// offered again the moment the search field is focused and empty
/// (Google-Maps style "previous searches").
///
/// Persisted as a small JSON file in the app support dir (same pattern as
/// AppSettings / QuickPlaces) so the list survives app restarts.
///
/// Entries are stored as plain [OsmSuggestion]s (coordinates already
/// resolved), so tapping one reuses the normal selection path — pin + place
/// card + "Chỉ đường" — with no network call at all.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:navbridge/services/osm_api.dart';

class RecentSearches extends ChangeNotifier {
  RecentSearches._();

  static final RecentSearches instance = RecentSearches._();

  /// Newest-first cap — older entries fall off the end.
  static const int maxEntries = 10;

  /// Test hook: read/write here instead of the platform app-support dir.
  @visibleForTesting
  static File? debugFileOverride;

  final List<OsmSuggestion> _items = [];

  /// Newest first.
  List<OsmSuggestion> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  /// Test hook: forget the in-memory list.
  @visibleForTesting
  void resetForTest() => _items.clear();

  Future<File> _file() async {
    final override = debugFileOverride;
    if (override != null) return override;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/search_history.json');
  }

  /// Read the persisted list once at startup. A missing / corrupt file is not
  /// fatal — the history just starts empty.
  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _items
        ..clear()
        ..addAll([
          for (final e in (raw['items'] as List? ?? const []))
            if (e is Map<String, dynamic>) _fromJson(e),
        ]);
      notifyListeners();
    } catch (_) {
      // Corrupt / unreadable history → start empty instead of crashing.
    }
  }

  /// Record [s] as the most recent search: de-duplicated (the same place
  /// searched twice moves to the top instead of appearing twice) and capped at
  /// [maxEntries].
  Future<void> add(OsmSuggestion s) async {
    final name = s.display.trim();
    if (name.isEmpty) return;
    if (s.lat.isNaN || s.lng.isNaN) return;
    // A suggestion still waiting for its place-detail lookup has no usable
    // coordinates yet — never store it (it would route to the ocean).
    if (s.lat == 0 && s.lng == 0) return;
    final entry = OsmSuggestion(
      refId: s.refId,
      display: name,
      lat: s.lat,
      lng: s.lng,
      source: s.source,
    );
    _items.removeWhere((x) => _samePlace(x, entry));
    _items.insert(0, entry);
    if (_items.length > maxEntries) {
      _items.removeRange(maxEntries, _items.length);
    }
    notifyListeners();
    await _save();
  }

  Future<void> remove(OsmSuggestion s) async {
    _items.removeWhere((x) => _samePlace(x, s));
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({'items': [for (final s in _items) _toJson(s)]}),
      );
    } catch (_) {
      // Persistence is best-effort: the in-memory list still works.
    }
  }

  static Map<String, dynamic> _toJson(OsmSuggestion s) => {
    'refId': s.refId,
    'display': s.display,
    'lat': s.lat,
    'lng': s.lng,
    'source': s.source,
  };

  static OsmSuggestion _fromJson(Map<String, dynamic> j) => OsmSuggestion(
    refId: (j['refId'] ?? '') as String,
    display: (j['display'] ?? '') as String,
    lat: ((j['lat'] ?? 0) as num).toDouble(),
    lng: ((j['lng'] ?? 0) as num).toDouble(),
    source: (j['source'] ?? 'osm') as String,
  );

  /// Same place? Either the same name (the geocoder returns slightly different
  /// coordinates for the same query) or within ~100 m of the stored one.
  static bool _samePlace(OsmSuggestion a, OsmSuggestion b) {
    if (_norm(a.display) == _norm(b.display)) return true;
    const epsilon = 0.001; // ≈110 m latitude — "same spot" for a search
    return (a.lat - b.lat).abs() < epsilon && (a.lng - b.lng).abs() < epsilon;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
