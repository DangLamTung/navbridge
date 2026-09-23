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
        self.grid_skipped = 0
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
            # Same guard as the Dart loader: a segment whose bounding box spans
            # more than 256 cells (0.005 deg each) is NOT indexed at all, so the
            # app can never find it near its interior either. Keeping the two
            # sides identical is what makes an offline audit comparable to the
            # app; the 140 affected segments are sea/ferry crossings.
            e5 = 500
            xs = [int(p * 1e5) // e5 for p in lngs]
            ys = [int(p * 1e5) // e5 for p in lats]
            if (max(xs) - min(xs) + 1) * (max(ys) - min(ys) + 1) > 256:
                self.grid_skipped += 1
                continue
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
                  f'{named} named), v{self.version}, cell {cell_e4}e-4, '
                  f'{self.grid_skipped} not indexed')

    def street(self, s: int):
        return self.streets[s] if s < len(self.streets) else None

    def value(self, s: int, heading_deg: float | None = None,
              bearing_deg: float | None = None):
        """Posted value of segment [s], for [heading_deg].

        The direction pick uses the bearing of the NEAREST SUB-SEGMENT in stored
        node order — exactly what the app does (`_querySegIndex` passes the
        winning candidate's bearing into the fwd/rev choice). Callers that have
        a position MUST pass [bearing_deg] (query() does); using the whole
        segment's end-to-end bearing instead inverts the answer on 95% of the
        25,127 per-direction segments in the asset (verified by
        tool/audit_waze_segments.py).
        """
        f, r = self.fwd[s], self.rev[s]
        if f == 0 and r == 0:
            return 0
        if f == r or f == 0:
            return r
        if r == 0:
            return f
        if heading_deg is None:
            return max(f, r)
        brg = self._bearing(s) if bearing_deg is None else bearing_deg
        delta = abs(heading_deg - brg) % 360.0
        if delta > 180:
            delta = 360 - delta
        return f if delta <= 90 else r

    def _bearing(self, s: int) -> float:
        """End-to-end bearing of the segment in STORED node order (first ->
        last). Fallback only — it ignores the segment's shape."""
        pts = self.pts[s]
        if len(pts) < 2:
            return 0.0
        (lat0, lng0) = pts[0]
        (lat1, lng1) = pts[-1]
        dx = (lng1 - lng0) * math.cos(math.radians(lat0))
        dy = lat1 - lat0
        return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0

    def query(self, lat: float, lng: float, heading_deg: float | None = None,
              max_dist_m: float = 25.0, rings: int = 1):
        """(kmh, street, road_class, divided, dist_m, seg_id) or (0, …, None).

        Picks the segment the car is IN, not merely the nearest one: a candidate
        whose nearest sub-segment the car has already passed (a positive
        OVERSHOOT beyond its end) or that runs across the car's heading is
        penalised out of range. Mirrors pickSegmentCandidate() in
        lib/services/offline_speed_limits.dart — if the two disagree, every
        offline audit of "did the app use the layer" is measuring something the
        app never did.
        """
        gy = int(math.floor(lat / CELL_DEG))
        gx = int(math.floor(lng / CELL_DEG))
        cands = []
        seen = set()
        # Same iteration order as the Dart loader (x outer, y inner) so that the
        # tie-break between two equally scored candidates lands on the same
        # segment on both sides.
        for dx in range(-rings, rings + 1):
            for dy in range(-rings, rings + 1):
                for s in self.grid.get((gy + dy, gx + dx), ()):
                    if s in seen:
                        continue
                    seen.add(s)
                    d, brg, over = self._geom(lat, lng, self.pts[s])
                    cands.append((s, d, brg, over))
        if not cands:
            return 0, None, 0, False, None, None
        best, best_score = None, float('inf')
        for s, d, brg, over in cands:
            # Hard range gate before scoring: an out-of-range segment must never
            # win, however clean it looks (see pickSegmentCandidate in Dart).
            if d > max_dist_m:
                continue
            score = segment_score(d, brg, heading_deg, max_dist_m, over)
            if score < best_score:
                best_score, best = score, (s, d)
        if best is None:
            return 0, None, 0, False, None, None
        s, best_d = best
        cls = (self.classes[s] & 0x3F) if self.classes else 0
        sep = bool(self.classes[s] & 0x80) if self.classes else False
        # The winning candidate's own bearing decides fwd vs rev — same as the
        # app, which reads brg from `cands[win].$3`.
        brg_win = next(c[2] for c in cands if c[0] == s)
        return (self.value(s, heading_deg, brg_win), self.street(s), cls, sep,
                best_d, s)

    @staticmethod
    def _geom(lat: float, lng: float, pts):
        """(perp distance m, bearing of nearest sub-segment, overshoot m).

        Overshoot > 0 means the car's projection lands PAST the end of that
        sub-segment (or before its start) — near the segment, not on it.
        """
        m_lng = M_PER_DEG_LAT * math.cos(math.radians(lat))
        px, py = lng * m_lng, lat * M_PER_DEG_LAT
        best = float('inf')
        bearing = 0.0
        over = 0.0
        for i in range(len(pts) - 1):
            ax, ay = pts[i][1] * m_lng, pts[i][0] * M_PER_DEG_LAT
            bx, by = pts[i + 1][1] * m_lng, pts[i + 1][0] * M_PER_DEG_LAT
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            if l2 <= 1e-9:
                continue
            t_raw = ((px - ax) * dx + (py - ay) * dy) / l2
            t = max(0.0, min(1.0, t_raw))
            cx, cy = ax + t * dx, ay + t * dy
            d = math.hypot(px - cx, py - cy)
            if d < best:
                best = d
                bearing = (math.degrees(math.atan2(
                    (bx - ax), (by - ay))) + 360.0) % 360.0
                ln = math.sqrt(l2)
                over = (-t_raw * ln) if t_raw < 0 else (
                    (t_raw - 1.0) * ln if t_raw > 1.0 else 0.0)
        return best, bearing, over

    @staticmethod
    def _dist(lat: float, lng: float, pts) -> float:
        return Segments._geom(lat, lng, pts)[0]


def segment_line_angle(heading_deg, bearing_deg) -> float:
    """Angle (0..90) between the car's heading and a segment's LINE."""
    if heading_deg is None:
        return 0.0
    d = abs(heading_deg - bearing_deg) % 180.0
    return 180.0 - d if d > 90.0 else d


def segment_score(distance_m: float, bearing_deg: float,
                  heading_deg, max_dist_m: float,
                  overshoot_m: float = 0.0) -> float:
    """Distance, penalised for a segment the car is not travelling along.

    Same two penalties as the Dart side: >45° off the car's heading (it runs
    across the path) and >10 m of overshoot (the car is past its end).
    """
    score = distance_m
    if heading_deg is not None and segment_line_angle(
            heading_deg, bearing_deg) > 45.0:
        score += max_dist_m + 1
    if overshoot_m > 10.0:
        score += max_dist_m + 1
    return score
