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

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:latlong2/latlong.dart';

import 'offline_loader.dart';

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
  //
  // Both the text and the binary layers go through the offline_loader readers,
  // so a copy downloaded by the updater wins over the bundled asset — before
  // this, the posted-limit layer read ONLY the bundle while the server
  // published updated copies of these files that nothing ever consumed.
  try {
    final raw = await readOfflineBytes('waze_segments.bin');
    _segs = await compute(_buildSegIndex, raw);
  } catch (_) {
    _segs = null;
  }
  // 2) Waze / VietMap posted-limit POINTS (sparse, but a real sign location).
  try {
    final raws = await Future.wait(<Future<String>>[
      readOfflineText('waze_speed_limits.json'),
      readOfflineText('vietmap_speed_limits.json'),
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

/// Drop the parsed layers so the next [loadOfflineSpeedLimits] re-reads them
/// from disk — called when an auto-update replaces a downloaded posted-limit
/// file, so the next lookup uses the fresh data instead of the APK's.
void reloadOfflineSpeedLimits() {
  _segs = null;
  _waze = null;
  _vietmap = null;
  _loaded = false;
  _loading = null;
  _lastLayer = null;
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
///
/// [keepKmh] is the value currently on screen. Two Waze records can run
/// parallel on ONE road a couple of metres apart, with different values and
/// even different spellings — measured on the 2026-09-22 20:48 drive, on
/// Cộng Hòa: id=601376 'Cộng Hòa' 60 at 3.0 m and id=603315 'Cộng Hoà' 50 at
/// 5.5 m. After diacritic folding those names are identical, so nothing but
/// CONTINUITY can tell them apart: whichever is nearest alternates with GPS
/// noise and the chip swapped 60/50 every second. A candidate carrying the
/// value already displayed therefore wins while it is within [keepBandM]
/// metres of the best candidate. Measured offline over that drive: 27
/// same-road value changes become 3 with a 6 m band, and 1 with 8 m.
/// One speed-limit answer, with everything needed to explain it — the source
/// layer, the street it came from and the segment id when the per-segment
/// layer answered — returned ATOMICALLY, so a caller can never pair one
/// lookup's limit with another lookup's street.
class SpeedLimitResult {
  const SpeedLimitResult({
    required this.limit,
    required this.source,
    this.streetName,
    this.segmentId,
    this.aligned = false,
  });

  final int limit;

  /// 'segment' | 'waze' | 'vietmap'.
  final String source;

  /// Street of the winning segment; null when the point layers answered.
  final String? streetName;

  /// Winning segment id, or null when the point layers answered.
  final int? segmentId;

  /// True when the winning segment is the road the car is RIDING — within
  /// [_maxAlignedDeg] of its heading — rather than one running across it.
  ///
  /// The segment layers name 62% of their records, and every name rule we have
  /// (`expectStreet`, the veto in `layerLimitMatchesNames`) exists to stop a
  /// CROSSING street's value being posted for our road. Being aligned is what
  /// actually distinguishes the road under the car from the one crossing it, so
  /// a caller may read `aligned` as "this record describes our road" — see
  /// `layerLimitMatchesNames`.
  final bool aligned;
}

/// The cascade, as an atomic result: Waze per-segment → Waze points →
/// VietMap points → null (the caller then keeps the graph/statutory value).
Future<SpeedLimitResult?> lookupSpeedLimit(
  LatLng p, {
  double maxDistM = 25,
  double? headingDeg,
  int? keepKmh,
  double keepBandM = 6,
  String? expectStreet,
}) async {
  await loadOfflineSpeedLimits();
  final segs = _segs;
  final waze = _waze;
  final vm = _vietmap;
  if (segs == null && waze == null && vm == null) return null;

  final lon = p.longitude, lat = p.latitude;
  final cosLat = math.cos(lat * math.pi / 180.0);

  if (segs != null) {
    final hit = _querySegIndex(segs, lat, lon, cosLat, maxDistM, headingDeg,
        keepKmh: keepKmh, keepBandM: keepBandM, expectStreet: expectStreet);
    if (hit != null) {
      return SpeedLimitResult(
        limit: hit.limit,
        source: 'segment',
        streetName: segs.streetName(hit.segmentId),
        segmentId: hit.segmentId,
        aligned: hit.aligned,
      );
    }
  }
  if (waze != null) {
    final r = _queryPointIndex(waze, lat, lon, cosLat, maxDistM);
    if (r != null) {
      return SpeedLimitResult(limit: r, source: 'waze');
    }
  }
  if (vm != null) {
    final r = _queryPointIndex(vm, lat, lon, cosLat, maxDistM);
    if (r != null) {
      return SpeedLimitResult(limit: r, source: 'vietmap');
    }
  }
  return null;
}

/// Limit only, for callers that do not need the street or the source.
///
/// Compatibility wrapper: it mirrors the result into the module globals that
/// [lastLimitLayer], [lastWazeStreetName] and [lastWazeSegmentId] expose, so a
/// caller that needs the pair must still read them immediately. Prefer
/// [lookupSpeedLimit] — it cannot be mispaired.
Future<int?> speedLimitAt(
  LatLng p, {
  double maxDistM = 25,
  double? headingDeg,
  int? keepKmh,
  double keepBandM = 6,
  String? expectStreet,
}) async {
  final res = await lookupSpeedLimit(
    p,
    maxDistM: maxDistM,
    headingDeg: headingDeg,
    keepKmh: keepKmh,
    keepBandM: keepBandM,
    expectStreet: expectStreet,
  );
  _lastLayer = res?.source;
  // -1, not "leave the previous segment": a point-layer answer must not keep
  // reporting the street of an older segment lookup (the segment layer can
  // also be absent entirely, in which case nothing else would reset it).
  _lastSegS = res?.segmentId ?? -1;
  return res?.limit;
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

/// Decodes one segment's point list. One instance per OPERATION (a query, a
/// bounds sweep, the index build) reused across segments: the varint cursor and
/// the point buffer are the decoder's own state, so two lookups can no longer
/// share — and corrupt — one module-level scratchpad.
class _SegDecoder {
  _SegDecoder(this.idx);

  final _SegIndex idx;

  /// Interleaved lat_e5/lng_e5 of the segment decoded last. Starts at the old
  /// fixed capacity (512 points) and grows past it on demand.
  Int32List pts = Int32List(2 * 512);

  /// Points in [pts] for the last [decode].
  int count = 0;

  /// Reports the first segment longer than the old 512-point cap, once per
  /// operation: the shipped asset tops out at 490, so this means the asset was
  /// re-exported with denser geometry and the tail would previously have been
  /// dropped silently.
  bool _growReported = false;

  /// Decode segment [s]; returns its point count. A segment longer than the
  /// buffer GROWS it — the old fixed 512-point buffer silently dropped the tail
  /// of anything longer (the WZSG coords are varint deltas, so a segment can be
  /// arbitrarily long), which would quietly shorten the road's geometry.
  int decode(int s) {
    final a = idx.coordBase + idx.offsets[s];
    final z = idx.coordBase + idx.offsets[s + 1];
    final b = idx.blob;
    var i = a;
    var n = 0;
    var lat = 0, lng = 0;
    while (i < z) {
      if (n * 2 + 2 > pts.length) {
        if (!_growReported) {
          _growReported = true;
          debugPrint('WAZE: segment $s exceeds ${pts.length ~/ 2} points');
        }
        final bigger = Int32List(pts.length * 2);
        bigger.setRange(0, n * 2, pts);
        pts = bigger;
      }
      var shift = 0, raw = 0;
      while (true) {
        final byte = b[i++];
        raw |= (byte & 0x7F) << shift;
        if (byte < 0x80) break;
        shift += 7;
      }
      final dLat = (raw >> 1) ^ -(raw & 1); // zigzag
      shift = 0;
      raw = 0;
      while (true) {
        final byte = b[i++];
        raw |= (byte & 0x7F) << shift;
        if (byte < 0x80) break;
        shift += 7;
      }
      final dLng = (raw >> 1) ^ -(raw & 1);
      lat = n == 0 ? dLat : lat + dLat;
      lng = n == 0 ? dLng : lng + dLng;
      pts[n * 2] = lat;
      pts[n * 2 + 1] = lng;
      n++;
    }
    count = n;
    return n;
  }
}
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

int lastWazeSegmentId() => _lastSegS;

class WazeSegment {
  const WazeSegment({
    required this.id,
    required this.points,
    required this.fwdKmh,
    required this.revKmh,
    required this.street,
  });

  final int id;
  final List<LatLng> points;

  final int fwdKmh;
  final int revKmh;

  final String street;

  int get limit => fwdKmh >= revKmh ? fwdKmh : revKmh;

  double get lengthMeters {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += const Distance().as(LengthUnit.Meter, points[i - 1], points[i]);
    }
    return total;
  }
}

List<WazeSegment> wazeSegmentsInBounds({
  double? south,
  double? west,
  double? north,
  double? east,
  int max = 3000,
}) {
  final idx = _segs;
  if (idx == null) return const [];
  final ids = <int>{};
  for (final entry in idx.grid.entries) {
    final cx = ((entry.key >> 16) & 0xFFFF).toSigned(16);
    final cy = (entry.key & 0xFFFF).toSigned(16);
    final lat = (cy + 0.5) * _segCellDeg;
    final lon = (cx + 0.5) * _segCellDeg;
    if (south != null && lat < south - _segCellDeg) continue;
    if (north != null && lat > north + _segCellDeg) continue;
    if (west != null && lon < west - _segCellDeg) continue;
    if (east != null && lon > east + _segCellDeg) continue;
    for (final s in entry.value) {
      ids.add(s);
    }
  }
  final out = <WazeSegment>[];
  final dec = _SegDecoder(idx);
  for (final s in ids) {
    if (out.length >= max) break;
    final n = dec.decode(s);
    if (n < 2) continue;
    final pts = <LatLng>[];
    var inBox = south == null && west == null && north == null && east == null;
    for (var i = 0; i < n; i++) {
      final lat = dec.pts[i * 2] / 1e5;
      final lng = dec.pts[i * 2 + 1] / 1e5;
      if (!inBox &&
          south != null &&
          west != null &&
          north != null &&
          east != null &&
          lat >= south &&
          lat <= north &&
          lng >= west &&
          lng <= east) {
        inBox = true;
      }
      pts.add(LatLng(lat, lng));
    }
    if (!inBox) continue;
    out.add(
      WazeSegment(
        id: s,
        points: pts,
        fwdKmh: idx.fwd[s],
        revKmh: idx.rev[s],
        street: idx.streetName(s) ?? '',
      ),
    );
  }
  return out;
}

bool get wazeSegmentsLoaded => _segs != null;

/// Decode segment [s] into [_segPts]. Returns the point count.
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
  final dec = _SegDecoder(idx);
  for (var s = 0; s < nSegs; s++) {
    final n = dec.decode(s);
    if (n < 2) continue;
    var minLat = 1 << 30,
        maxLat = -(1 << 30),
        minLng = 1 << 30,
        maxLng = -(1 << 30);
    for (var k = 0; k < n; k++) {
      final la = dec.pts[k * 2], ln = dec.pts[k * 2 + 1];
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
/// bearing of the nearest sub-segment and how far PAST that sub-segment's end
/// the car sits.
///
/// [overshoot] is 0 while the car's projection lands ON the sub-segment. A
/// positive value means the car has driven beyond this segment's extent (or has
/// not reached its start yet) — it is near the segment, but NOT on it, which is
/// the difference between "the nearest segment" and "the segment I am driving".
(double, double, double) _segDistBearing(
  _SegDecoder dec,
  int s,
  double lat,
  double lon,
  double cosLat,
) {
  final n = dec.decode(s);
  var best = double.infinity;
  var bearing = 0.0;
  var overshoot = 0.0;
  for (var k = 0; k < n - 1; k++) {
    final alat = dec.pts[k * 2] / 1e5, alng = dec.pts[k * 2 + 1] / 1e5;
    final blat = dec.pts[k * 2 + 2] / 1e5;
    final blng = dec.pts[k * 2 + 3] / 1e5;
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
      // Unclamped projection parameter → how far off the ends the car is.
      final tRaw = l2 > 1e-9 ? (-ax * dx - ay * dy) / l2 : 0.0;
      final len = math.sqrt(l2);
      overshoot = tRaw < 0 ? -tRaw * len : (tRaw > 1 ? (tRaw - 1) * len : 0.0);
    }
  }
  return (best, bearing, overshoot);
}

/// Angle (deg, 0..90) between the car's heading and a segment's LINE.
///
/// The LINE, not a direction: a street and its opposite carriageway are the same
/// road (mod 180), so a car travelling 180° against a segment's stored node order
/// is still on it.
double segmentLineAngle(double? headingDeg, double bearingDeg) {
  if (headingDeg == null) return 0;
  var d = (headingDeg - bearingDeg).abs() % 180.0;
  if (d > 90) d = 180 - d;
  return d;
}

bool streetNameMatches(String? road, String? segment) {
  if (road == null || segment == null) return false;
  final a = _streetTokens(road);
  final b = _streetTokens(segment);
  if (a.isEmpty || b.isEmpty) return false;
  // A name matches ITSELF, however short its token: 'QL1' == 'QL1' is the road
  // the entire 1,686 km Hà Nội → Sài Gòn drive runs on, and the short-token
  // rule below (min 4 chars) refused it — so as soon as the screen showed "QL1"
  // and the page passed it as `expectStreet`, EVERY posted limit on the route
  // was dropped and the dial read '-' for a thousand kilometres
  // (measured 2026-09-27). Token-joined comparison also makes 'QL1' match
  // 'QL 1', the way the two sources spell the same highway.
  //
  // Except when the name says nothing at all: 'Đường' is the word "street" and
  // '30' is a number — identical or not, neither identifies a road
  // (test/speed_limit_result_test.dart pins that).
  if (a.join() == b.join() && !_isUninformativeName(a)) return true;
  if (a.any(_isAlleyToken) != b.any(_isAlleyToken)) return false;
  final shared = [for (final t in a) if (b.contains(t)) t];
  if (shared.isEmpty) return false;
  if (shared.length != a.length && shared.length != b.length) return false;
  if (shared.length >= 2) return true;
  final only = shared.single;
  return only.length >= 4 && !_genericStreetTokens.contains(only);
}

const Set<String> _genericStreetTokens = {
  'đường',
  'phố',
  'đại',
  'tỉnh',
  'quốc',
  'huyện',
  'xã',
  'phường',
  'khu',
  'ấp',
  'tổ',
};

bool _isAlleyToken(String t) =>
    const {'hẻm', 'kiệt', 'ngõ', 'ngách', 'hẻmnhánh'}.contains(t);

/// True when the name carries no identity: every token is a generic road word
/// ("Đường", "Tỉnh", "Quốc"…) or a bare number ("30"). Such a name cannot say
/// WHICH road it is, so even two identical ones are not evidence of a match.
bool _isUninformativeName(List<String> tokens) =>
    tokens.isEmpty ||
    tokens.every(
      (t) => _genericStreetTokens.contains(t) || int.tryParse(t) != null,
    );

List<String> _streetTokens(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final isDigit = r >= 0x30 && r <= 0x39;
    final isAsciiLetter = r >= 0x61 && r <= 0x7A;
    final isUniLetter =
        (r >= 0x00C0 && r <= 0x024F) || (r >= 0x1EA0 && r <= 0x1EFF);
    if (isDigit || isAsciiLetter || isUniLetter) {
      buf.writeCharCode(r);
    } else if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

const double _nameBandM = 60;

/// Angle (deg) past which a segment is treated as running ACROSS the car rather
/// than under it.  Used by [segmentScore] and [_pickWithContinuity].
const double _maxAlignedDeg = 45.0;

/// Metres a candidate's nearest sub-segment may lie BEYOND the car before the
/// car counts as having driven off that segment's end.  Used by [segmentScore].
const double _maxOvershootM = 10.0;



/// Candidate score for the segment lookup: distance, penalised when the segment
/// runs ACROSS the car's path.
///
/// Nearest-wins is not enough at a junction: the crossing street's segment can be
/// a metre closer than the road under the car, and with 15-20 m GPS accuracy
/// which one wins flips fix by fix. Measured on the 2026-09-21 drive, the street
/// name alternated 'Lũy Bán Bích' ↔ 'Đường 30 Tháng 4' for 17 s at one junction
/// while the car drove straight north up Đường 30 Tháng 4 — and because the
/// name AND the limit come from the same segment record, the driver heard the
/// crossing street's name paired with the other road's limit (user: "the limit
/// said Lũy Bán Bích · residential when I had entered Đường 30 Tháng 4").
///
/// The penalty exceeds [maxDistM], so any aligned segment in range beats any
/// misaligned one, while a car stopped mid-turn (nothing aligned) still falls
/// back to the nearest segment rather than to nothing at all.
double segmentScore(
  double distanceM,
  double bearingDeg,
  double? headingDeg,
  double maxDistM, {
  double overshootM = 0,
}) {
  var score = distanceM;
  if (headingDeg != null &&
      segmentLineAngle(headingDeg, bearingDeg) > _maxAlignedDeg) {
    score += maxDistM + 1;
  }
  // "The car is IN the segment": a projection that lands past either end is
  // not on it (the car has driven off the end, or has not reached the start).
  if (overshootM > _maxOvershootM) score += maxDistM + 1;
  return score;
}
/// Index of the candidate to trust among (segment, distance m, bearing,
/// overshoot m) tuples, or -1 when nothing is within [maxDistM]. On-segment and
/// aligned candidates first, then distance — see [segmentScore] for why.
int pickSegmentCandidate(
  List<(int, double, double, double)> candidates,
  double? headingDeg,
  double maxDistM,
) {
  var bestI = -1;
  var bestScore = double.infinity;
  for (var i = 0; i < candidates.length; i++) {
    final (_, d, brg, over) = candidates[i];
    // HARD range gate, before any scoring: a segment out of range must never
    // win, however clean it looks. Scoring first let a tidy candidate 30 m away
    // beat the slightly misaligned one 4 m under the car, and the lookup then
    // answered "no limit" while the car sat plainly on a segment — measured on
    // the 17:45 junction of the 2026-09-21 drive, where every fix in the window
    // came back empty.
    if (d > maxDistM) continue;
    final score = segmentScore(d, brg, headingDeg, maxDistM, overshootM: over);
    if (score < bestScore) {
      bestScore = score;
      bestI = i;
    }
  }
  return bestI;
}

/// How many segments of the pack lie within [radiusM] of [p].
///
/// The built-up ("khu đông dân cư") signal for `urban_area.dart`. The POI pack
/// (17 029 points) cannot answer that question: 698 of the country's 1 375 OSM
/// towns have NO POI within 2 km, so even a threshold of one POI detects only
/// 49 % of them.
///
/// ⚠️ COUNT EACH SEGMENT ONCE. The loader registers a segment in every grid
/// cell its BOUNDING BOX covers (`_buildSegIndex`), so summing `ids.length`
/// counted a segment once per cell — i.e. it measured bounding-box area, not
/// road density. Measured 2026-09-28: an empty rice field in Hà Nam 2 km from
/// a highway scored **657** and was called a town, and every one of nine probe
/// points (three of them open country) came out "urban", so the built-up rule
/// was effectively always true and the app used the town limit in the
/// countryside. Deduping by segment id is what makes the number mean "roads
/// near here": the same field then scores ~0-25 and towns keep their hundreds.
///
/// Returns 0 when the pack is unavailable, which callers read as "not built-up"
/// (the conservative direction: the rural table is the lower limit in town).
Future<int> segmentDensity(LatLng p, {double radiusM = 2000}) async {
  await loadOfflineSpeedLimits();
  final idx = _segs;
  if (idx == null) return 0;
  final cosLat = math.cos(p.latitude * math.pi / 180.0);
  final cx = (p.longitude / _segCellDeg).floor();
  final cy = (p.latitude / _segCellDeg).floor();
  final span = (radiusM / (_segCellDeg * 111320.0)).ceil();
  // Generation-stamped "seen" array: O(1) per id, no Set allocated per call
  // (this probe runs every 150 m during navigation).
  var seen = _densitySeen;
  if (seen == null || seen.length != idx.fwd.length) {
    seen = Uint32List(idx.fwd.length);
    _densitySeen = seen;
    _densityGen = 0;
  }
  if (_densityGen >= 0xFFFFFFF0) {
    seen.fillRange(0, seen.length, 0);
    _densityGen = 0;
  }
  final gen = ++_densityGen;
  var n = 0;
  for (var dx = -span; dx <= span; dx++) {
    for (var dy = -span; dy <= span; dy++) {
      // Cell CENTRE inside the radius: counting the whole square would inflate
      // the corners by ~40 % area.
      final lat = (cy + dy + 0.5) * _segCellDeg;
      final lon = (cx + dx + 0.5) * _segCellDeg;
      final dLat = (lat - p.latitude) * 111320.0;
      final dLon = (lon - p.longitude) * 111320.0 * cosLat;
      if (dLat * dLat + dLon * dLon > radiusM * radiusM) continue;
      final ids = idx.grid[(((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF)];
      if (ids == null) continue;
      for (final id in ids) {
        if (seen[id] == gen) continue;
        seen[id] = gen;
        n++;
      }
    }
  }
  return n;
}

/// Reusable dedupe stamps for [segmentDensity] (see its doc for why).
Uint32List? _densitySeen;
int _densityGen = 0;

/// Posted limit (km/h) of the segment the car is on within [maxDistM] of
/// (lat, lon), or null.
///
/// [keepKmh] (see [speedLimitAt]) makes the pick CONTINUOUS inside the
/// ambiguity band: between two parallel records of one road, the one carrying
/// the value already on screen wins while it is within [keepBandM] metres of
/// the best candidate. Without it the value alternates with GPS noise.
({int limit, int segmentId, bool aligned})? _querySegIndex(
  _SegIndex idx,
  double lat,
  double lon,
  double cosLat,
  double maxDistM,
  double? headingDeg, {
  int? keepKmh,
  double keepBandM = 6,
  String? expectStreet,
}) {
  final cx = (lon / _segCellDeg).floor();
  final cy = (lat / _segCellDeg).floor();
  // Small list per query (~1 Hz), traded for one place that decides which
  // segment wins: the two-accumulator version this replaced could not express
  // "prefer the aligned one", which is why a junction could rename the road.
  final cands =
      <(int, double, double, double)>[]; // (segment, dist, bearing, overshoot)
  final dec = _SegDecoder(idx);
  for (var dx = -1; dx <= 1; dx++) {
    for (var dy = -1; dy <= 1; dy++) {
      final key = (((cx + dx) & 0xFFFF) << 16) | ((cy + dy) & 0xFFFF);
      final ids = idx.grid[key];
      if (ids == null) continue;
      for (var k = 0; k < ids.length; k++) {
        final s = ids[k];
        final (d, brg, over) = _segDistBearing(dec, s, lat, lon, cosLat);
        cands.add((s, d, brg, over));
      }
    }
  }
  final pick = _pickWithContinuity(
      idx, cands, headingDeg, maxDistM, keepKmh, keepBandM,
      expectStreet: expectStreet);
  // No winner ⇒ nothing usable here: no limit, and no segment to name the road
  // from either (the caller adopts the street verbatim, even on a null limit).
  if (pick.win < 0) return null;
  final s = cands[pick.win].$1;
  final brg = cands[pick.win].$3;
  // If expectStreet was given, only accept candidates matching that street name
  // unless chosen by geometry override (car is demonstrably riding this road).
  if (!pick.byGeometry &&
      expectStreet != null &&
      expectStreet.trim().isNotEmpty) {
    final street = idx.streetName(s);
    if (street != null &&
        street.trim().isNotEmpty &&
        !streetNameMatches(expectStreet, street)) {
      return null;
    }
  }
  // Only answer when the segment actually posts a limit: zero segments in the
  // current asset carry 0/0, but an OTA asset may, and a 0 km/h answer would
  // otherwise override the graph/statutory value.
  if (idx.fwd[s] == 0 && idx.rev[s] == 0) return null;
  // `aligned`: is the car RIDING this segment (rather than crossing it)? A
  // ridden segment is evidence about the road under the car whatever name we
  // happen to hold — see `layerLimitMatchesNames`'s `ridden`.
  //
  // ⚠ An UNKNOWN heading is NOT "riding it". `headingDeg` is null whenever the
  // fix carries no course — the first seconds of every drive, because the page
  // passes `_heading == 0 ? null : _heading` — and `ridden: true` switches the
  // name veto OFF in `layerLimitMatchesNames`. `segmentScore` is blind at the
  // same moment, since its across-the-car penalty also needs a heading, so
  // answering "ridden" there would adopt a crossing street's value AND name with
  // nothing checking either. "Cannot tell" must read as the conservative side.
  final aligned = headingDeg != null &&
      segmentLineAngle(headingDeg, brg) <= _maxAlignedDeg;
  return (
    limit: _segmentValue(idx, s, brg, headingDeg),
    segmentId: s,
    aligned: aligned,
  );
}

/// The value a segment would answer for [headingDeg]: its own `fwd`/`rev` pair
/// resolved against the bearing of the sub-segment nearest the car.
int _segmentValue(_SegIndex idx, int s, double brg, double? headingDeg) {
  final f = idx.fwd[s], r = idx.rev[s];
  int val;
  if (f == r || f == 0) {
    val = r;
  } else if (r == 0) {
    val = f;
  } else if (headingDeg == null) {
    val = f > r ? f : r;
  } else {
    // Pick the direction the car is actually travelling: within 90 deg of the
    // segment's stored node order means it is riding the `fwd` direction.
    var delta = (headingDeg - brg).abs() % 360.0;
    if (delta > 180) delta = 360 - delta;
    val = delta <= 90 ? f : r;
  }

  // Statutory ceiling: in Vietnam, speeds > 90 km/h (100-120 km/h) are legal
  // EXCLUSIVELY on expressways (Freeway rt=3 or streetName indicating CT/Cao tốc).
  if (val > 90) {
    final (rt, div) = idx.segClassOf(s);
    if (rt != 3) {
      final name = idx.streetName(s) ?? '';
      final isExp = name.startsWith('CT') ||
          name.contains('Cao tốc') ||
          name.contains('Expressway');
      if (!isExp) {
        val = div ? 90 : 80;
      }
    }
  }

  return val;
}

/// Winner among [cands], holding [keepKmh] when it is still plausible.
///
/// Returns the index AND how it was chosen: `byGeometry` is true when the winner
/// was picked over the name we were given because the geometry winner is clearly
/// better AND aligned with the car heading.  The caller must not then veto it on
/// Winner among [cands], holding [keepKmh] when it is still plausible.
///
/// Returns the winning index and whether it was chosen by geometry override
/// (`byGeometry: true`), which bypasses the name veto when the car is demonstrably
/// riding a different road (e.g. turning onto a primary road while the road matcher
/// still holds the crossing tertiary name).
({int win, bool byGeometry}) _pickWithContinuity(
  _SegIndex idx,
  List<(int, double, double, double)> cands,
  double? headingDeg,
  double maxDistM,
  int? keepKmh,
  double keepBandM, {
  String? expectStreet,
}) {
  if (cands.isEmpty) return (win: -1, byGeometry: false);

  var ids = <int>[for (var i = 0; i < cands.length; i++) i];
  var radius = maxDistM;
  if (expectStreet != null && expectStreet.trim().isNotEmpty) {
    final inside = <int>[
      for (final i in ids)
        if (cands[i].$2 <= maxDistM &&
            streetNameMatches(expectStreet, idx.streetName(cands[i].$1)))
          i,
    ];
    final band = inside.isNotEmpty
        ? inside
        : <int>[
            for (final i in ids)
              if (cands[i].$2 <= _nameBandM &&
                  streetNameMatches(expectStreet, idx.streetName(cands[i].$1)))
                i,
          ];
    if (band.isNotEmpty) {
      ids = band;
      radius = inside.isNotEmpty ? maxDistM : _nameBandM;
    }
  }
  final pool = [for (final i in ids) cands[i]];
  final winPool = pickSegmentCandidate(pool, headingDeg, radius);
  if (winPool < 0) return (win: -1, byGeometry: false);
  var win = ids[winPool];

  // Geometry rescue: a segment the car is demonstrably RIDING must not be
  // excluded by a stale expectStreet.
  //
  // Strict criteria to prevent false overrides at cross-street junctions
  // (such as the Tân Thành pinned case):
  // 1. Heading must be known.
  // 2. Full-pool geometry winner must be directly under the car (<= 15m),
  //    projected directly onto the segment (overshoot <= 5m), and tightly
  //    aligned with the car's direction of travel (line angle <= 25°).
  // 3. The name candidate must have positive evidence of NOT being the road
  //    driven: overshoot > 10m (car has driven past its end) AND angle > 60°
  //    (runs across the car's path).
  // 4. They must be different streets with a substantial score gap.
  if (expectStreet != null &&
      expectStreet.trim().isNotEmpty &&
      headingDeg != null) {
    final fullWin = pickSegmentCandidate(cands, headingDeg, maxDistM);
    if (fullWin >= 0 && fullWin != win) {
      final geoCand = cands[fullWin];
      final nameCand = cands[win];
      final geoAngle = segmentLineAngle(headingDeg, geoCand.$3);
      final nameAngle = segmentLineAngle(headingDeg, nameCand.$3);

      final geoIsRidden =
          geoCand.$2 <= 15.0 && geoCand.$4 <= 5.0 && geoAngle <= 25.0;
      final nameIsOffRoad =
          nameCand.$4 > _maxOvershootM && nameAngle > 60.0;

      if (geoIsRidden &&
          nameIsOffRoad &&
          !streetNameMatches(
              idx.streetName(nameCand.$1), idx.streetName(geoCand.$1))) {
        final geoScore = segmentScore(
            geoCand.$2, geoCand.$3, headingDeg, maxDistM,
            overshootM: geoCand.$4);
        final nameScore = segmentScore(
            nameCand.$2, nameCand.$3, headingDeg, radius,
            overshootM: nameCand.$4);
        if (nameScore - geoScore > 20.0) {
          return (win: fullWin, byGeometry: true);
        }
      }
    }
  }

  // keepKmh continuity tiebreaker (prevents GPS-noise toggling)
  if (keepKmh == null || keepKmh <= 0) return (win: win, byGeometry: false);
  final bestD = cands[win].$2;
  var stickyI = -1;
  var stickyD = double.infinity;
  for (final i in ids) {
    final (s, d, brg, _) = cands[i];
    if (d > radius) continue;
    if (d > bestD + keepBandM) continue;
    if (_segmentValue(idx, s, brg, headingDeg) != keepKmh) continue;
    if (d < stickyD) {
      stickyD = d;
      stickyI = i;
    }
  }
  return (win: stickyI >= 0 ? stickyI : win, byGeometry: false);
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
