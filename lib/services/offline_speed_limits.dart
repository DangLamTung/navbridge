/// Offline posted speed-limit layer for Việt Nam — real posted signs from the
/// Waze crawl + VietMap E-DOG, bundled as POINT layers. A point within a few
/// metres of the car wins over the OSM statutory class default.
///
/// The DATMAP segment layer was REMOVED (2026-09-14): its per-segment values
/// were wrong on city roads (e.g. a 60 km/h divided road read 50). The road
/// class / name still come from OSM (GraphHopper/Overpass); the posted limit
/// now comes from Waze → VietMap → OSM `maxspeed` → statutory class default.
///
/// Works with NO network. The point layers are parsed once in a BACKGROUND
/// isolate into a uniform lon/lat grid index, so lookups are O(1) neighbours.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Grid cell size in degrees (~2.2 km at the equator). Query touches 3×3 cells.
const double _cellDeg = 0.02;

/// Metres per degree of latitude (local planar approximation).
const double _mPerDeg = 111320.0;

/// Real Waze WME posted speed limits as SEGMENTS (per direction) — queried
/// FIRST. Built by `tools/signs/build_waze_segments.py` from the Decode_Waze
/// crawl; see that script for the binary layout.
_SegIndex? _segs;

/// Real Waze posted speed limits as POINTS — queried FIRST in [speedLimitAt].
_WazeIndex? _waze;

/// VietMap E-DOG posted speed limits as POINTS (official posted limits).
/// Queried after Waze.
_WazeIndex? _vietmap;

bool _loaded = false;
Future<void>? _loading;

/// Whether the speed-limit layer is ready to answer queries.
bool get speedLimitsLoaded =>
    _segs != null || _waze != null || _vietmap != null;

/// Whether the speed-limit layer actually has DATA. The public repo ships
/// empty placeholder files for the enforcement DBs (real Waze/VietMap data is
/// generated locally and bundled only on the build machine), so tests use this
/// to skip assertions that need real crawled/posted limits.
bool get speedLimitsPopulated {
  if (!speedLimitsLoaded) return false;
  if (_segs != null && _segs!.offsets.length > 1) return true;
  if (_waze != null && _waze!.pts.isNotEmpty) return true;
  if (_vietmap != null && _vietmap!.pts.isNotEmpty) return true;
  return false;
}

/// Load (and index) the bundled speed-limit layers once. Idempotent + cached;
/// the heavy parses run in background isolates so the first call never janks
/// the UI. Each layer loads independently — a missing/placeholder asset for
/// one must not disable the others.
Future<void> loadOfflineSpeedLimits() {
  if (_loaded) return Future.value();
  if (_loading != null) return _loading!;
  final fut = _doLoad();
  _loading = fut;
  return fut;
}

Future<void> _doLoad() async {
  // 1) Waze WME per-SEGMENT limits — the dense layer (95% of HCMC segments).
  try {
    final bytes = await rootBundle.load('assets/offline_map/waze_segments.bin');
    final raw = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    _segs = await compute(_buildSegIndex, raw);
  } catch (_) {
    _segs = null;
  }
  // 2) Waze / VietMap posted-limit POINTS (sparse, but a real sign location).
  try {
    final raws = await Future.wait(<Future<String>>[
      rootBundle.loadString('assets/offline_map/waze_speed_limits.json'),
      rootBundle.loadString('assets/offline_map/vietmap_speed_limits.json'),
    ]);
    _waze = await compute(_buildWazeIndex, raws[0]);
    _vietmap = await compute(_buildWazeIndex, raws[1]);
  } catch (_) {
    _waze = null;
    _vietmap = null;
  }
  _loaded = true;
  _loading = null;
  // Never surface an error here: [speedLimitAt] (and the fire-and-forget
  // nav correction) must degrade to the statutory default on a bad load,
  // not throw an unhandled async exception.
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

/// Posted speed limit (km/h) of the nearest Waze SEGMENT, Waze point or
/// VietMap point within [maxDistM] of [p], or null when nothing credible is
/// nearby. Loads the layers on first use; afterwards it is instant.
///
/// Query order, most trustworthy first:
///   1. Waze WME **segment** limit — per direction, 95.6% of HCMC segments and
///      ~70% of segments nationwide. This is what the driver actually sees on
///      a sign, keyed to the stretch of road under the car.
///   2. Waze posted-limit POINTS (from the mod's map comments, types 12/13).
///   3. VietMap E-DOG official posted limits.
/// Returning null leaves the caller on the OSM `maxspeed` / statutory default.
///
/// [headingDeg] (compass, 0 = north) picks the right direction when a segment
/// posts different limits for each carriageway; without it the higher of the
/// two is used, which is the safe read for a limit *ceiling*.
Future<int?> speedLimitAt(
  LatLng p, {
  double maxDistM = 25,
  double? headingDeg,
}) async {
  await loadOfflineSpeedLimits();
  final segs = _segs;
  final waze = _waze;
  final vm = _vietmap;
  if (segs == null && waze == null && vm == null) return null;

  final lon = p.longitude, lat = p.latitude;
  final cosLat = math.cos(lat * math.pi / 180.0);

  // 1) Waze per-SEGMENT limits.
  if (segs != null) {
    final r = _querySegIndex(segs, lat, lon, cosLat, maxDistM, headingDeg);
    if (r != null) {
      _lastLayer = 'segment';
      return r;
    }
  }
  // 2) Waze point layer — the driver trusts Waze's real posted limits.
  if (waze != null) {
    final r = _queryPointIndex(waze, lat, lon, cosLat, maxDistM);
    if (r != null) {
      _lastLayer = 'waze';
      return r;
    }
  }
  // 3) VietMap E-DOG official posted limits.
  if (vm != null) {
    final r = _queryPointIndex(vm, lat, lon, cosLat, maxDistM);
    if (r != null) {
      _lastLayer = 'vietmap';
      return r;
    }
  }
  _lastLayer = null;
  return null;
}

// ---------------------------------------------------------------------------
// Waze WME per-segment layer
// ---------------------------------------------------------------------------

/// Grid cell for the segment layer, in degrees (0.005 deg ~ 550 m), so a 3x3
/// query window is ~1.6 km — tight enough that a dense city scan stays cheap.
const double _segCellDeg = 0.005;

/// Byte size of the v3 `WZSG` header: 4s + 6 u32 + 2 i32 + 1 u32 = 40.
/// v2 was 36 (no street table). Change BOTH sides together — a mismatch
/// silently misreads every array offset.
const int _segHeaderBytes = 40;

/// v2 header size, still accepted so an older OTA asset keeps loading.
const int _segHeaderBytesV2 = 36;

/// Waze WME posted limits per road SEGMENT, packed for O(1) lookups. Binary
/// layout is documented in `tools/signs/build_waze_segments.py`.
///
/// v2 stores coordinates as a zigzag-varint delta stream (first point of a
/// segment absolute, the rest relative). That keeps the nationwide asset at
/// ~22 MB instead of the 49 MB an int32 + node-table layout needed.
class _SegIndex {
  final Uint8List blob; // whole asset (aligned copy)
  final int coordBase; // byte offset of the varint stream inside [blob]
  final Uint32List offsets; // nSegs + 1 BYTE offsets into the stream
  final Uint8List fwd; // km/h, 0 = unknown
  final Uint8List rev;
  final Map<int, Uint32List> grid;

  /// v3 street table, addressed by BYTE offset rather than typed-list views:
  /// `segStreet` sits after two odd-length u8 arrays, so its byte offset is
  /// not 4-byte aligned and `asUint32List` would throw. Reading on demand also
  /// avoids materialising another 4 MB of Uint32List for 1.03 M segments.
  /// A negative base means the asset is v2 (no street table).
  final int segStreetBase; // nSegs * u32 -> street index, 0xFFFFFFFF = none
  final int segClassBase; // nSegs * u8  -> roadType (bits 0-5) | sep (bit 7)
  final int streetOffBase; // (nStreets + 1) * u32
  final int namesBase; // UTF-8, NUL-terminated street names
  final ByteData views; // ByteData over [blob] for the on-demand reads

  const _SegIndex({
    required this.blob,
    required this.coordBase,
    required this.offsets,
    required this.fwd,
    required this.rev,
    required this.grid,
    required this.views,
    this.segStreetBase = -1,
    this.segClassBase = -1,
    this.streetOffBase = -1,
    this.namesBase = -1,
  });

  int get length => fwd.length;

  /// Street name of segment [s], or null when that segment carries none.
  ///
  /// Waze leaves most segments unnamed (37.8% named nationwide, 55.7% in
  /// HCMC), so callers MUST read null as "unknown — fall back to another
  /// source", never as an error.
  String? streetName(int s) {
    if (segStreetBase < 0 || s < 0 || s >= fwd.length) return null;
    final i = views.getUint32(segStreetBase + s * 4, Endian.little);
    if (i == 0xFFFFFFFF) return null;
    final a = views.getUint32(streetOffBase + i * 4, Endian.little);
    final z = views.getUint32(streetOffBase + (i + 1) * 4, Endian.little);
    if (z <= a + 1) return null;
    return utf8.decode(
      Uint8List.sublistView(blob, namesBase + a, namesBase + z - 1),
      allowMalformed: true,
    );
  }

  /// WME roadType of segment [s] (0 when unknown) and whether WME marked the
  /// carriageways as separated.
  ///
  /// CAUTION: `separator` is `false` on **every one of the 1,033,546 segments**
  /// in this crawl, so it carries NO signal today — do not drive the
  /// divided-road (50 vs 60) rule from it.
  (int, bool) segClassOf(int s) {
    if (segClassBase < 0 || s < 0 || s >= fwd.length) return (0, false);
    final v = blob[segClassBase + s];
    return (v & 0x3F, (v & 0x80) != 0);
  }
}

// Varint decode scratch — the loader and the query path are single-threaded,
// so a pair of module-level slots avoids allocating per coordinate.
int _viVal = 0;
int _viNext = 0;

void _readVarint(Uint8List b, int i) {
  var shift = 0;
  var raw = 0;
  while (true) {
    final byte = b[i++];
    raw |= (byte & 0x7F) << shift;
    if (byte < 0x80) break;
    shift += 7;
  }
  _viVal = (raw >> 1) ^ -(raw & 1); // zigzag
  _viNext = i;
}

/// Decoded points of one segment, as lat_e5, lng_e5 pairs. Reused between
/// calls — never hold on to it.
Int32List _segPts = Int32List(2 * 64);

/// Segment that produced the most recent [_querySegIndex] hit, so callers can
/// read its street name ([lastWazeStreetName]) from the SAME record that gave
/// the limit — the whole point of the v3 street table. -1 when nothing hit.
int _lastSegS = -1;

/// Which LAYER produced the most recent [speedLimitAt] result:
/// 'segment' | 'waze' | 'vietmap', or null when nothing matched. Read it
/// immediately after `speedLimitAt` (the next lookup overwrites it) — it is
/// what the widget's source badge shows.
String? lastLimitLayer() => _lastLayer;

String? _lastLayer;

/// Street name of the Waze segment that produced the most recent
/// [speedLimitAt] result, or null when that segment carries no name (most
/// don't) or nothing matched.
///
/// Call this immediately after `speedLimitAt` for the same position; a later
/// lookup overwrites it.
String? lastWazeStreetName() {
  final idx = _segs;
  final s = _lastSegS;
  if (idx == null || s < 0) return null;
  return idx.streetName(s);
}

/// Decode segment [s] into [_segPts]. Returns the point count.
int _decodeSeg(_SegIndex idx, int s) {
  final a = idx.coordBase + idx.offsets[s];
  final z = idx.coordBase + idx.offsets[s + 1];
  final b = idx.blob;
  if (_segPts.length < 2 * 512) _segPts = Int32List(2 * 512);
  var i = a;
  var n = 0;
  var lat = 0, lng = 0;
  while (i < z && n < 511) {
    _readVarint(b, i);
    final dLat = _viVal;
    i = _viNext;
    _readVarint(b, i);
    final dLng = _viVal;
    i = _viNext;
    lat = n == 0 ? dLat : lat + dLat;
    lng = n == 0 ? dLng : lng + dLng;
    _segPts[n * 2] = lat;
    _segPts[n * 2 + 1] = lng;
    n++;
  }
  return n;
}

_SegIndex _buildSegIndex(Uint8List raw) {
  // Copy first: rootBundle's ByteData can sit at a non-4-byte offset, and the
  // typed views below require an aligned buffer.
  final b = Uint8List.fromList(raw);
  if (b.lengthInBytes < _segHeaderBytes) {
    throw const FormatException('speed segment: short');
  }
  if (String.fromCharCodes(b.sublist(0, 4)) != 'WZSG') {
    throw const FormatException('speed segment: bad magic');
  }
  final bd = ByteData.sublistView(b);
  final ver = bd.getUint32(4, Endian.little);
  if (ver != 2 && ver != 3) {
    throw const FormatException('speed segment: unsupported version');
  }
  final nSegs = bd.getUint32(16, Endian.little);
  final nCoordB = bd.getUint32(12, Endian.little);
  var off = ver >= 3 ? _segHeaderBytes : _segHeaderBytesV2;
  final offsets = b.buffer.asUint32List(b.offsetInBytes + off, nSegs + 1);
  off += (nSegs + 1) * 4;
  final coordBase = off;
  off += nCoordB;
  final fwd = b.buffer.asUint8List(b.offsetInBytes + off, nSegs);
  off += nSegs;
  final rev = b.buffer.asUint8List(b.offsetInBytes + off, nSegs);
  off += nSegs;
  // v3 street table. Absent in v2, where every base stays -1 and the street
  // lookups simply return null.
  var segStreetBase = -1, segClassBase = -1, streetOffBase = -1, namesBase = -1;
  if (ver >= 3) {
    final nStreets = bd.getUint32(24, Endian.little);
    final nameBlobB = bd.getUint32(36, Endian.little);
    segStreetBase = off;
    off += nSegs * 4;
    segClassBase = off;
    off += nSegs;
    streetOffBase = off;
    off += (nStreets + 1) * 4;
    namesBase = off;
    off += nameBlobB;
  }

  final idx = _SegIndex(
    blob: b,
    coordBase: coordBase,
    offsets: offsets,
    fwd: fwd,
    rev: rev,
    grid: const {},
    views: bd,
    segStreetBase: segStreetBase,
    segClassBase: segClassBase,
    streetOffBase: streetOffBase,
    namesBase: namesBase,
  );

  // Grid: index every segment into each cell its bounding box touches, so a
  // query never misses a segment that crosses a cell border.
  const cellE5 = 500; // 0.005 deg in 1e-5 deg units
  final grid = <int, List<int>>{};
  for (var s = 0; s < nSegs; s++) {
    final n = _decodeSeg(idx, s);
    if (n < 2) continue;
    var minLat = 1 << 30,
        maxLat = -(1 << 30),
        minLng = 1 << 30,
        maxLng = -(1 << 30);
    for (var k = 0; k < n; k++) {
      final la = _segPts[k * 2], ln = _segPts[k * 2 + 1];
      if (la < minLat) minLat = la;
      if (la > maxLat) maxLat = la;
      if (ln < minLng) minLng = ln;
      if (ln > maxLng) maxLng = ln;
    }
    final x0 = minLng ~/ cellE5, x1 = maxLng ~/ cellE5;
    final y0 = minLat ~/ cellE5, y1 = maxLat ~/ cellE5;
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 256) continue; // pathological
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final key = ((x & 0xFFFF) << 16) | (y & 0xFFFF);
        (grid[key] ??= <int>[]).add(s);
      }
    }
  }
  return _SegIndex(
    blob: b,
    coordBase: coordBase,
    offsets: offsets,
    fwd: fwd,
    rev: rev,
    grid: {for (final e in grid.entries) e.key: Uint32List.fromList(e.value)},
    views: bd,
    segStreetBase: segStreetBase,
    segClassBase: segClassBase,
    streetOffBase: streetOffBase,
    namesBase: namesBase,
  );
}

/// Compass bearing (deg, 0 = north) of a segment node pair.
double _bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  final dLat = lat2 - lat1;
  final dLng = (lng2 - lng1) * math.cos(lat1 * math.pi / 180.0);
  return (math.atan2(dLng, dLat) * 180.0 / math.pi + 360.0) % 360.0;
}

/// Perpendicular distance (m) from a segment polyline to (lat, lon), plus the
/// bearing of the nearest sub-segment.
(double, double) _segDistBearing(
  _SegIndex idx,
  int s,
  double lat,
  double lon,
  double cosLat,
) {
  final n = _decodeSeg(idx, s);
  var best = double.infinity;
  var bearing = 0.0;
  for (var k = 0; k < n - 1; k++) {
    final alat = _segPts[k * 2] / 1e5, alng = _segPts[k * 2 + 1] / 1e5;
    final blat = _segPts[k * 2 + 2] / 1e5;
    final blng = _segPts[k * 2 + 3] / 1e5;
    final ax = (alng - lon) * _mPerDeg * cosLat;
    final ay = (alat - lat) * _mPerDeg;
    final bx = (blng - lon) * _mPerDeg * cosLat;
    final by = (blat - lat) * _mPerDeg;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = 0.0;
    if (l2 > 1e-9) t = ((-ax * dx - ay * dy) / l2).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < best) {
      best = d;
      bearing = _bearingDeg(alat, alng, blat, blng);
    }
  }
  return (best, bearing);
}

/// Posted limit (km/h) of the nearest Waze segment within [maxDistM] of
/// (lat, lon), or null. [headingDeg] disambiguates a per-direction limit; when
/// absent (or when only one direction is posted) the higher value wins, since
/// the caller treats the result as a limit ceiling.
int? _querySegIndex(
  _SegIndex idx,
  double lat,
  double lon,
  double cosLat,
  double maxDistM,
  double? headingDeg,
) {
  final cx = (lon / _segCellDeg).floor();
  final cy = (lat / _segCellDeg).floor();
  var best = double.infinity;
  var bestFwd = 0, bestRev = 0;
  var bestBearing = 0.0;
  _lastSegS = -1; // which segment won, for [lastWazeStreetName]
  for (var dx = -1; dx <= 1; dx++) {
    for (var dy = -1; dy <= 1; dy++) {
      final key = (((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF);
      final ids = idx.grid[key];
      if (ids == null) continue;
      for (var k = 0; k < ids.length; k++) {
        final s = ids[k];
        final (d, brg) = _segDistBearing(idx, s, lat, lon, cosLat);
        if (d < best) {
          best = d;
          bestBearing = brg;
          bestFwd = idx.fwd[s];
          bestRev = idx.rev[s];
          _lastSegS = s;
        }
      }
    }
  }
  if (best > maxDistM) return null;
  final f = bestFwd, r = bestRev;
  if (f == 0 && r == 0) return null;
  if (f == r || f == 0) return r;
  if (r == 0) return f;
  if (headingDeg == null) return f > r ? f : r;
  // Pick the direction the car is actually travelling: within 90 deg of the
  // segment's stored node order means it is riding the `fwd` direction.
  var delta = (headingDeg - bestBearing).abs() % 360.0;
  if (delta > 180) delta = 360 - delta;
  return delta <= 90 ? f : r;
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
