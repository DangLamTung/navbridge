/// Is the car inside a built-up area (khu đông dân cư)? — answered from the
/// bundled POI layer, so the statutory limit can switch between the urban and
/// the rural table when no posted limit is known.
///
/// Why not the boundary signs: the OSM/VietMap "bắt đầu / hết khu đông dân cư"
/// points are mapped PER ROAD SEGMENT and were removed for being wrong most of
/// the time (see `droppedSignKinds`). POI density is a different kind of
/// evidence — a property of the place, not of one way's tagging.
///
/// Measured separation (tool/urban_probe.py, 17,029 bundled POIs, 2 km radius):
///   HCMC centre 591 · HCMC Quận 7 118 · Hà Nội 593
///   rural Tây Ninh 0 · Đắk Nông 0 · QL1 Phú Yên 0
/// so [kUrbanPoiMin] = 25 sits in a very wide gap.
///
/// The city rule is a CEILING for a road whose class the graph only knows
/// relatively (a `primary` is 80 km/h for a car in the countryside and 50 in
/// town). A posted sign or a Waze segment value always wins over it.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// POIs within [kUrbanRadiusM] needed to call a place built-up. 25 is two
/// orders of magnitude below a city centre and above the rural samples (0).
const int kUrbanPoiMin = 25;

/// Radius of the density probe, metres.
const double kUrbanRadiusM = 2000;

/// Grid cell for the density index, degrees (~1.1 km at 10° N).
const double _cell = 0.01;

/// Lazily-built index: cell → POI count. Only the COUNTS are kept — the
/// density test never needs the individual points, so the 17k list is
/// discarded after the build and the map is a few thousand ints.
Map<int, int>? _grid;

int _key(int cy, int cx) => (cy << 16) | (cx & 0xFFFF);

/// Number of bundled POIs within [kUrbanRadiusM] of [p]. O(9 cells).
Future<int> poiDensity(LatLng p) async {
  final g = await _loadGrid();
  if (g.isEmpty) return 0;
  final cy = (p.latitude / _cell).floor();
  final cx = (p.longitude / _cell).floor();
  // ~2 km = 2 cells at this latitude; scan 5x5 to be safe.
  var n = 0;
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      n += g[_key(cy + dy, cx + dx)] ?? 0;
    }
  }
  return n;
}

/// True when [p] looks built-up (khu đông dân cư) by POI density.
Future<bool> isUrbanArea(LatLng p) async => await poiDensity(p) >= kUrbanPoiMin;

Future<Map<int, int>> _loadGrid() async {
  final cached = _grid;
  if (cached != null) return cached;
  final counts = <int, int>{};
  try {
    final raw = await rootBundle.loadString(
      'assets/offline_map/vietnam_pois.json',
    );
    final doc = jsonDecode(raw);
    if (doc is Map) {
      for (final cat in doc.values) {
        if (cat is! Map) continue;
        final items = cat['items'];
        if (items is! List) continue;
        for (final it in items) {
          if (it is! Map) continue;
          final lat = it['lat'], lng = it['lng'];
          if (lat is! num || lng is! num) continue;
          final cy = (lat / _cell).floor();
          final cx = (lng / _cell).floor();
          final k = _key(cy, cx);
          counts[k] = (counts[k] ?? 0) + 1;
        }
      }
    }
  } catch (_) {
    // No POI layer (or unreadable) → never claim a built-up area. The caller
    // then keeps the rural/class default, which is the conservative read.
    return _grid = const {};
  }
  return _grid = counts;
}

/// Drop the cached index (after an asset update). Test hook.
void resetUrbanAreaCache() => _grid = null;
