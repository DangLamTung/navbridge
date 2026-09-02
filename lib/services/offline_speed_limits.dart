/// Offline nationwide speed-limit layer for Việt Nam — bundled as a GeoJSON
/// (`assets/offline_map/vietnam_speed_limits.geojson`) with 93,463 real road
/// segments extracted from DATMAP traffic tiles (the app's live speed-limit
/// data, decrypted from its per-tile AES-GCM payloads).
///
/// Works with NO network (like `offline_cameras.dart`). During navigation the
/// app queries the posted speed limit at the current GPS position; when the
/// nearest segment (within a few metres) carries a real limit, that value
/// overwrites the statutory class default that the offline graph can only
/// estimate.
///
/// Memory: the 22 MB GeoJSON is parsed once in a BACKGROUND ISOLATE into
/// compact typed arrays + a uniform lon/lat grid index, so lookups are O(1)
/// neighbours (no linear scan over all 93k segments) and the UI thread never
/// blocks on the parse.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Per-segment metadata stride in [_SpeedLimitIndex.meta]:
/// [fwdSpeed, revSpeed, minLon, minLat, maxLon, maxLat, midLon, midLat].
const int _metaStride = 8;

/// Grid cell size in degrees (~2.2 km at the equator). Query touches 3×3 cells.
const double _cellDeg = 0.02;

/// Metres per degree of latitude (local planar approximation).
const double _mPerDeg = 111320.0;

/// The parsed, indexed layer. Built once in an isolate and held by the
/// library so repeated calls are instant.
class _SpeedLimitIndex {
  /// Per segment: [fwd, rev, minLon, minLat, maxLon, maxLat, midLon, midLat].
  final Float32List meta;
  final Float32List coords; // packed [lon, lat, lon, lat, …]
  final Uint32List offsets; // start coord index per segment (n+1 entries)
  final Map<int, Uint32List> grid; // cell key -> segment ids

  const _SpeedLimitIndex({
    required this.meta,
    required this.coords,
    required this.offsets,
    required this.grid,
  });
}

_SpeedLimitIndex? _index;

/// Real Waze posted speed limits as POINTS (from the Waze crawl — the driver
/// trusts these over the sparse DATMAP layer). Queried FIRST in
/// [speedLimitAt]; a Waze point within the window wins over a DATMAP segment.
_WazeIndex? _waze;

/// VietMap E-DOG posted speed limits as POINTS (22k+ official posted limits).
/// Queried after Waze; any point within the window beats a DATMAP segment.
_WazeIndex? _vietmap;

bool _loaded = false;
Future<void>? _loading;

/// Whether the speed-limit layer is ready to answer queries.
bool get speedLimitsLoaded => _index != null;

/// Load (and index) the bundled speed-limit layer once. Idempotent + cached;
/// the heavy parse runs in a background isolate so the first call never
/// janks the UI.
Future<void> loadOfflineSpeedLimits() {
  if (_loaded) return Future.value();
  if (_loading != null) return _loading!;
  final fut = _doLoad();
  _loading = fut;
  return fut;
}

Future<void> _doLoad() async {
  try {
    final raws = await Future.wait(<Future<String>>[
      rootBundle.loadString('assets/offline_map/vietnam_speed_limits.geojson'),
      rootBundle.loadString('assets/offline_map/waze_speed_limits.json'),
      rootBundle.loadString('assets/offline_map/vietmap_speed_limits.json'),
    ]);
    _index = await compute(_buildIndex, raws[0]);
    _waze = await compute(_buildWazeIndex, raws[1]);
    _vietmap = await compute(_buildWazeIndex, raws[2]);
    _loaded = true;
  } catch (_) {
    // Keep null on any failure — queries return null (statutory default).
    _index = null;
    _waze = null;
    _vietmap = null;
  } finally {
    _loading = null;
  }
  // Never surface an error here: [speedLimitAt] (and the fire-and-forget
  // nav correction) must degrade to the statutory default on a bad load,
  // not throw an unhandled async exception.
}

/// Top-level (isolate-safe) worker: parse the GeoJSON string into the
/// compact indexed structure.
_SpeedLimitIndex _buildIndex(String raw) {
  final fc = jsonDecode(raw) as Map<String, dynamic>;
  final features = (fc['features'] as List?) ?? const [];
  final n = features.length;
  final meta = Float32List(n * _metaStride);
  final coords = <double>[];
  final offsets = Uint32List(n + 1);
  final grid = <int, List<int>>{};

  for (var i = 0; i < n; i++) {
    final f = features[i] as Map<String, dynamic>;
    final geom = (f['geometry'] as Map<String, dynamic>?) ?? const {};
    final line = ((geom['coordinates'] as List?) ?? const []);
    final props = (f['properties'] as Map<String, dynamic>?) ?? const {};
    final fwd = ((props['fwdMaxSpeed'] ?? 0) as num).toDouble();
    final rev = ((props['revMaxSpeed'] ?? 0) as num).toDouble();

    final off = i * _metaStride;
    meta[off] = fwd;
    meta[off + 1] = rev;
    offsets[i] = coords.length ~/ 2;

    var minLon = 1e9, minLat = 1e9, maxLon = -1e9, maxLat = -1e9;
    var sx = 0.0, sy = 0.0, cnt = 0;
    for (final c in line) {
      final lon = (c[0] as num).toDouble();
      final lat = (c[1] as num).toDouble();
      coords.add(lon);
      coords.add(lat);
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      sx += lon;
      sy += lat;
      cnt++;
    }
    meta[off + 2] = minLon;
    meta[off + 3] = minLat;
    meta[off + 4] = maxLon;
    meta[off + 5] = maxLat;
    meta[off + 6] = cnt > 0 ? sx / cnt : 0.0;
    meta[off + 7] = cnt > 0 ? sy / cnt : 0.0;
    if (cnt > 0) {
      final key = _cellKey(meta[off + 6], meta[off + 7]);
      (grid[key] ??= <int>[]).add(i);
    }
  }
  offsets[n] = coords.length ~/ 2;

  return _SpeedLimitIndex(
    meta: meta,
    coords: Float32List.fromList(coords),
    offsets: offsets,
    grid: {for (final e in grid.entries) e.key: Uint32List.fromList(e.value)},
  );
}

/// Waze speed-limit POINTS: packed Float32List [lat, lng, kmh, …] + a grid
/// (cell -> point indices), built in a background isolate.
class _WazeIndex {
  final Float32List pts;
  final Map<int, Uint32List> grid;
  const _WazeIndex({required this.pts, required this.grid});
}

_WazeIndex _buildWazeIndex(String raw) {
  final d = jsonDecode(raw) as Map<String, dynamic>;
  final points = (d['points'] as List?) ?? const [];
  final pts = <double>[];
  final grid = <int, List<int>>{};
  for (final p in points) {
    if (p is! Map) continue;
    final lat = (p['lat'] as num?)?.toDouble();
    final lng = (p['lng'] as num?)?.toDouble();
    final kmh = (p['kmh'] as num?)?.toDouble();
    if (lat == null || lng == null || kmh == null) continue;
    if (kmh < 5 || kmh > 200) continue;
    final idx = pts.length ~/ 3;
    pts
      ..add(lat)
      ..add(lng)
      ..add(kmh);
    final key = _cellKey(lng, lat);
    (grid[key] ??= <int>[]).add(idx);
  }
  return _WazeIndex(
    pts: Float32List.fromList(pts),
    grid: {for (final e in grid.entries) e.key: Uint32List.fromList(e.value)},
  );
}

int _cellKey(double lon, double lat) {
  final x = (lon / _cellDeg).floor();
  final y = (lat / _cellDeg).floor();
  return ((x & 0xFFFF) << 16) | (y & 0xFFFF);
}

/// Posted speed limit (km/h) of the nearest DATMAP segment within
/// [maxDistM] of [p], or null when nothing credible is nearby. Loads the
/// layer on first use; afterwards it is instant.
Future<int?> speedLimitAt(LatLng p, {double maxDistM = 25}) async {
  await loadOfflineSpeedLimits();
  final idx = _index;
  final waze = _waze;
  final vm = _vietmap;
  if (idx == null && waze == null && vm == null) return null;

  final lon = p.longitude, lat = p.latitude;
  final cosLat = math.cos(lat * math.pi / 180.0);
  final maxDeg = maxDistM / _mPerDeg;

  // 1) WAZE point layer FIRST — the driver trusts Waze's real posted limits.
  if (waze != null) {
    final r = _queryPointIndex(waze, lat, lon, cosLat, maxDistM);
    if (r != null) return r;
  }
  // 2) VietMap E-DOG official posted limits — beats the sparse DATMAP segments.
  if (vm != null) {
    final r = _queryPointIndex(vm, lat, lon, cosLat, maxDistM);
    if (r != null) return r;
  }
  if (idx == null) return null;

  final meta = idx.meta;
  final coords = idx.coords;
  final offsets = idx.offsets;
  final grid = idx.grid;
  final cx = (lon / _cellDeg).floor();
  final cy = (lat / _cellDeg).floor();

  var best = double.infinity;
  var bestSpeed = 0.0;
  for (var dx = -1; dx <= 1; dx++) {
    for (var dy = -1; dy <= 1; dy++) {
      final key = (((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF);
      final ids = grid[key];
      if (ids == null) continue;
      for (var k = 0; k < ids.length; k++) {
        final i = ids[k];
        final off = i * _metaStride;
        // Bounding-box reject before the point-to-polyline distance.
        if (lon < meta[off + 2] - maxDeg ||
            lon > meta[off + 4] + maxDeg ||
            lat < meta[off + 3] - maxDeg ||
            lat > meta[off + 5] + maxDeg) {
          continue;
        }
        final d = _segDistM(coords, offsets, i, lon, lat, cosLat);
        if (d < best) {
          best = d;
          final fwd = meta[off];
          final rev = meta[off + 1];
          // Prefer the higher of the two directional limits when both set.
          bestSpeed = fwd > 0 && rev > 0
              ? math.max(fwd, rev)
              : (fwd > 0 ? fwd : rev);
        }
      }
    }
  }
  if (best <= maxDistM && bestSpeed >= 5 && bestSpeed <= 200) {
    return bestSpeed.round();
  }
  return null;
}

/// Nearest point limit (km/h) in a [`_WazeIndex`] (Waze or VietMap E-DOG)
/// within [maxDistM] of (lat, lon), or null. Shared by both point layers.
int? _queryPointIndex(
  _WazeIndex idx,
  double lat,
  double lon,
  double cosLat,
  double maxDistM,
) {
  final cx = (lon / _cellDeg).floor();
  final cy = (lat / _cellDeg).floor();
  final pts = idx.pts;
  var best = double.infinity;
  var bestKmh = 0.0;
  for (var dx = -1; dx <= 1; dx++) {
    for (var dy = -1; dy <= 1; dy++) {
      final key = (((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF);
      final ids = idx.grid[key];
      if (ids == null) continue;
      for (var k = 0; k < ids.length; k++) {
        final i = ids[k] * 3;
        final kmh = pts[i + 2];
        if (kmh < 5 || kmh > 200) continue;
        final d = _ptDistM(pts[i], pts[i + 1], lat, lon, cosLat);
        if (d < best) {
          best = d;
          bestKmh = kmh;
        }
      }
    }
  }
  if (best <= maxDistM) return bestKmh.round();
  return null;
}

/// Great-circle-ish planar distance (m) from a Waze POINT to (lat, lon).
double _ptDistM(
  double plat,
  double plng,
  double lat,
  double lon,
  double cosLat,
) {
  final dLat = (plat - lat) * _mPerDeg;
  final dLon = (plng - lon) * _mPerDeg * cosLat;
  return math.sqrt(dLat * dLat + dLon * dLon);
}

/// Minimum distance (m) from (lon, lat) to segment [i]'s polyline.
double _segDistM(
  Float32List coords,
  Uint32List offsets,
  int i,
  double lon,
  double lat,
  double cosLat,
) {
  final a = offsets[i] * 2;
  final b = offsets[i + 1] * 2;
  if (b - a < 4) return double.infinity;
  var minD2 = double.infinity;
  var px = coords[a], py = coords[a + 1];
  for (var k = a + 2; k < b; k += 2) {
    final qx = coords[k], qy = coords[k + 1];
    minD2 = math.min(minD2, _ptSegDeg2(lon, lat, px, py, qx, qy, cosLat));
    px = qx;
    py = qy;
  }
  return math.sqrt(minD2) * _mPerDeg;
}

/// Squared distance (in lat-degrees², lon scaled by [cosLat]) from a point to
/// a segment (a→b).
double _ptSegDeg2(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
  double cosLat,
) {
  final axx = ax * cosLat, bxx = bx * cosLat, pxx = px * cosLat;
  final dx = bxx - axx, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) {
    final ex = pxx - axx, ey = py - ay;
    return ex * ex + ey * ey;
  }
  final t = (((pxx - axx) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  final cxx = axx + t * dx, cyy = ay + t * dy;
  final ex = pxx - cxx, ey = py - cyy;
  return ex * ex + ey * ey;
}
