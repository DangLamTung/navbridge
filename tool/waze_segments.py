#!/usr/bin/env python3
"""Reader for the app's Waze SEGMENT layer (`assets/offline_map/waze_segments.bin`).

This is the layer `speedLimitAt()` queries FIRST, so it is the app's primary
"posted limit" source. It is the reference for `tool/trip_truth.py` and the B
side of `tool/compare_speed_sources.py`, so the parser lives here once.

Format (WZSG), little-endian — see tools/signs/build_waze_segments.py:

    header 40 bytes   magic 'WZSG', ver, nPoints, nCoordBytes, nSegs, cellE4,
                      nStreets, lat0e5, lng0e5, streetBlobBytes   (v2: 36 bytes)
    offsets  (nSegs+1) u32   byte offset of each segment in the coord stream
    coords   nCoordB         zigzag varint lat/lng @1e-5 deg, delta-coded
    fwd      nSegs u8        km/h, 0 = unknown
    rev      nSegs u8        km/h, 0 = unknown
    segStreet nSegs u32      index into the street table (v3+)
    segClass  nSegs u8       roadType bits 0-5 | divided-carriageway bit 7
    streetOff (nStreets+1) u32
    names    streetBlobB     UTF-8, NUL-terminated

Query semantics mirror lib/services/offline_speed_limits.dart:
  * nearest segment within `max_dist_m` (the app uses 25 m),
  * 0/0 → no limit; fwd==rev → that value; else pick by HEADING: within 90° of
    the segment's stored node order means the car rides `fwd`. No heading → the
    higher of the two.
"""
from __future__ import annotations

import math
import struct
from collections import defaultdict

M_PER_DEG_LAT = 111320.0
CELL_DEG = 0.005  # matches _segCellDeg in the Dart loader


def _varint(buf: bytes, i: int):
    shift = 0
    raw = 0
    while True:
        b = buf[i]
        i += 1
        raw |= (b & 0x7F) << shift
        if b < 0x80:
            break
        shift += 7
    return (raw >> 1) ^ -(raw & 1), i


class Segments:
    """Parsed v2/v3 WZSG blob with a 0.005° grid."""

    def __init__(self, path: str, verbose: bool = False, only_with_limit=False):
        with open(path, 'rb') as fh:
            blob = fh.read()
        (magic, self.version, n_pts, n_coord_b, self.n_segs, cell_e4,
         n_streets, _lat0, _lng0, name_b) = struct.unpack_from('<4sIIIIIIiiI',
                                                             blob, 0)
        if magic != b'WZSG':
            raise SystemExit(f'{path}: bad magic {magic!r} (not a WZSG blob)')
        self.cell_e4 = cell_e4
        off = 40 if self.version >= 3 else 36
        self.offsets = struct.unpack_from(f'<{self.n_segs + 1}I', blob, off)
        off += (self.n_segs + 1) * 4
        self.coord_base = off
        off += n_coord_b
        self.fwd = blob[off:off + self.n_segs]
        off += self.n_segs
        self.rev = blob[off:off + self.n_segs]
        off += self.n_segs
        self.streets: list[str | None] = []
        self.classes = b''
        if self.version >= 3:
            seg_street_off = off
            off += self.n_segs * 4
            seg_class_off = off
            off += self.n_segs
            street_off_off = off
            off += (n_streets + 1) * 4
            names_off = off

            def name_at(i: int):
                if i == 0xFFFFFFFF:
                    return None
                a = struct.unpack_from('<I', blob, street_off_off + i * 4)[0]
                z = struct.unpack_from('<I', blob, street_off_off + (i + 1) * 4)[0]
                raw = blob[names_off + a:names_off + z].split(b'\x00')[0]
                return raw.decode('utf-8', 'replace') or None

            idxs = struct.unpack_from(f'<{self.n_segs}I', blob, seg_street_off)
            self.streets = [name_at(i) for i in idxs]
            self.classes = blob[seg_class_off:seg_class_off + self.n_segs]

        # Geometry + grid. Segments are stored so that consecutive points are a
        # few metres apart, so the polyline distance gives a good answer.
        self.pts: list[list[tuple[float, float]]] = []
        self.grid: dict[tuple[int, int], list[int]] = defaultdict(list)
        keep = 0
        for s in range(self.n_segs):
            if only_with_limit and not (self.fwd[s] or self.rev[s]):
                self.pts.append([])
                continue
            a = self.coord_base + self.offsets[s]
            z = self.coord_base + self.offsets[s + 1]
            i = a
            lat = lng = 0
            pts = []
            while i < z:
                d_lat, i = _varint(blob, i)
                d_lng, i = _varint(blob, i)
                lat = d_lat if not pts else lat + d_lat
                lng = d_lng if not pts else lng + d_lng
                pts.append((lat / 1e5, lng / 1e5))
            self.pts.append(pts)
            keep += 1
            if not pts:
                continue
            lats = [p[0] for p in pts]
            lngs = [p[1] for p in pts]
            for gy in range(int(math.floor(min(lats) / CELL_DEG)),
                            int(math.floor(max(lats) / CELL_DEG)) + 1):
                for gx in range(int(math.floor(min(lngs) / CELL_DEG)),
                                int(math.floor(max(lngs) / CELL_DEG)) + 1):
                    self.grid[(gy, gx)].append(s)
        if verbose:
            with_lim = sum(1 for s in range(self.n_segs)
                           if self.fwd[s] or self.rev[s])
            named = sum(1 for n in self.streets if n)
            print(f'segments: {self.n_segs} ({with_lim} with a limit, '
                  f'{named} named), v{self.version}, cell {cell_e4}e-4')

    def street(self, s: int):
        return self.streets[s] if s < len(self.streets) else None

    def value(self, s: int, heading_deg: float | None = None):
        f, r = self.fwd[s], self.rev[s]
        if f == 0 and r == 0:
            return 0
        if f == r or f == 0:
            return r
        if r == 0:
            return f
        if heading_deg is None:
            return max(f, r)
        brg = self._bearing(s)
        delta = abs(heading_deg - brg) % 360.0
        if delta > 180:
            delta = 360 - delta
        return f if delta <= 90 else r

    def _bearing(self, s: int) -> float:
        pts = self.pts[s]
        if not pts:
            return 0.0
        (lat0, lng0) = pts[-1]
        (lat1, lng1) = pts[0]
        dx = (lng1 - lng0) * math.cos(math.radians(lat0))
        dy = lat1 - lat0
        return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0

    def query(self, lat: float, lng: float, heading_deg: float | None = None,
              max_dist_m: float = 25.0, rings: int = 1):
        """(kmh, street, road_class, divided, dist_m, seg_id) or (0, …, None)."""
        gy = int(math.floor(lat / CELL_DEG))
        gx = int(math.floor(lng / CELL_DEG))
        best, best_d = None, float('inf')
        seen = set()
        for dy in range(-rings, rings + 1):
            for dx in range(-rings, rings + 1):
                for s in self.grid.get((gy + dy, gx + dx), ()):
                    if s in seen:
                        continue
                    seen.add(s)
                    d = self._dist(lat, lng, self.pts[s])
                    if d < best_d:
                        best, best_d = s, d
        if best is None or best_d > max_dist_m:
            return 0, None, 0, False, (None if best is None else best_d), None
        cls = (self.classes[best] & 0x3F) if self.classes else 0
        sep = bool(self.classes[best] & 0x80) if self.classes else False
        return (self.value(best, heading_deg), self.street(best), cls, sep,
                best_d, best)

    @staticmethod
    def _dist(lat: float, lng: float, pts) -> float:
        m_lng = M_PER_DEG_LAT * math.cos(math.radians(lat))
        px, py = lng * m_lng, lat * M_PER_DEG_LAT
        best = float('inf')
        for i in range(len(pts)):
            ax, ay = pts[i][1] * m_lng, pts[i][0] * M_PER_DEG_LAT
            if i + 1 < len(pts):
                bx, by = pts[i + 1][1] * m_lng, pts[i + 1][0] * M_PER_DEG_LAT
            else:
                bx, by = ax, ay
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            t = 0.0 if l2 == 0 else max(
                0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
            cx, cy = ax + t * dx, ay + t * dy
            d = math.hypot(px - cx, py - cy)
            if d < best:
                best = d
        return best
