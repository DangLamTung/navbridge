/// A tiny uniform lat/lng grid for "points near a position" queries.
///
/// The offline camera/sign layers scan their whole database on every browse-map
/// refresh (32k cameras and 11k signs). That is cheap on a desktop but a
/// measurable main-thread stall on a low-end phone, and the work grows with the
/// nationwide index. Bucketing every point ONCE turns the per-refresh scan into
/// a walk over a handful of cells.
///
/// Cells are 0.02° (~2.2 km). A 6 km query touches ~13×13 cells, but only the
/// non-empty ones are iterated — the caller still applies the exact haversine
/// distance, so a cell edge never changes an answer.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class PointGrid<T> {
  static const double defaultCellDeg = 0.02;

  final double cellDeg;
  final LatLng Function(T) posOf;
  final Map<int, List<T>> _cells = {};

  PointGrid(
    Iterable<T> items, {
    required this.posOf,
    this.cellDeg = defaultCellDeg,
  }) {
    for (final item in items) {
      final p = posOf(item);
      final key = _key(
        (p.latitude / cellDeg).floor(),
        (p.longitude / cellDeg).floor(),
      );
      (_cells[key] ??= <T>[]).add(item);
    }
  }

  /// Việt Nam's lat/lng are positive and well under 1000°, so a single int
  /// (y * 10_000 + x) is a collision-free key here.
  int _key(int y, int x) => y * 10000 + x;

  /// Items in the cells touched by a circle of [radiusM] around [lat]/[lng].
  /// Candidates only — the caller must still check the real distance.
  Iterable<T> near(double lat, double lng, double radiusM) sync* {
    final latSpan = radiusM / 111320.0;
    final cosLat = math.max(0.2, math.cos(lat * math.pi / 180.0));
    final lngSpan = latSpan / cosLat;
    final y0 = ((lat - latSpan) / cellDeg).floor();
    final y1 = ((lat + latSpan) / cellDeg).floor();
    final x0 = ((lng - lngSpan) / cellDeg).floor();
    final x1 = ((lng + lngSpan) / cellDeg).floor();
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final bucket = _cells[_key(y, x)];
        if (bucket == null) continue;
        yield* bucket;
      }
    }
  }
}
