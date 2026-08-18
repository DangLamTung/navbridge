/// Saved quick destinations ("Nhà riêng" / "Cơ quan" / …) for one-tap
/// navigation, Google-Maps style. Persisted as a small JSON file in the app
/// support dir (same pattern as AppSettings) so they survive restarts.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A saved quick destination: an id (home/work/…), a display label, the
/// address/name of the saved spot, and its coordinates.
class QuickPlace {
  final String id; // 'home', 'work', ...
  final String label; // 'Nhà riêng', 'Cơ quan', ...
  final String name; // address / place name
  final double lat;
  final double lng;

  const QuickPlace({
    required this.id,
    required this.label,
    required this.name,
    required this.lat,
    required this.lng,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'name': name,
    'lat': lat,
    'lng': lng,
  };

  factory QuickPlace.fromJson(Map<String, dynamic> j) => QuickPlace(
    id: j['id'] as String,
    label: j['label'] as String,
    name: j['name'] as String? ?? '',
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
  );
}

/// Persisted store of named quick places. Default slots: home + work (the
/// two the user asked for); the list is extensible for more later.
class QuickPlaces {
  QuickPlaces._();
  static final QuickPlaces instance = QuickPlaces._();

  /// Label per slot id (unset slots render as a "+ Nhà riêng" / "+ Cơ quan"
  /// chip).
  static const Map<String, String> _labels = {
    'home': 'Nhà riêng',
    'work': 'Cơ quan',
  };

  /// Ordered slot ids — the user can drag to reorder them in the UI.
  List<String> _order = ['home', 'work'];
  List<QuickPlace> _places = [];

  /// Ordered slots (id, label) for the UI row.
  List<(String, String)> get slots => [
    for (final id in _order) (id, _labels[id] ?? id),
  ];

  List<QuickPlace> get places => List.unmodifiable(_places);

  QuickPlace? byId(String id) {
    for (final p in _places) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) {
        _order = ['home', 'work'];
        _places = [];
        return;
      }
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _order = [
        for (final o in (j['order'] as List? ?? ['home', 'work'])) o as String,
      ];
      _places = [
        for (final e in (j['places'] as List? ?? const []))
          if (e is Map<String, dynamic>) QuickPlace.fromJson(e),
      ];
    } catch (_) {
      _order = ['home', 'work'];
      _places = [];
    }
  }

  /// Save (or update) a place under [id]. Empties name/coords clear it.
  Future<void> set(
    String id,
    String label,
    String name,
    double lat,
    double lng,
  ) async {
    _places = [
      for (final p in _places)
        if (p.id != id) p,
      QuickPlace(id: id, label: label, name: name, lat: lat, lng: lng),
    ];
    await _save();
  }

  /// Move a slot from [from] to [to] (drag-reorder) and persist.
  Future<void> reorder(int from, int to) async {
    if (from < 0 ||
        from >= _order.length ||
        to < 0 ||
        to >= _order.length ||
        from == to) {
      return;
    }
    final item = _order.removeAt(from);
    _order.insert(to, item);
    await _save();
  }

  /// Replace the whole slot order (drag-reorder drop) and persist.
  Future<void> setOrder(List<String> order) async {
    _order = List.of(order);
    await _save();
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'order': _order,
          'places': [for (final p in _places) p.toJson()],
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<File> _file() async {
    final sup = await getApplicationSupportDirectory();
    return File('${sup.path}/quick_places.json');
  }
}
