#!/usr/bin/env python3
"""Build the Waze Map Editor (WME) per-SEGMENT speed-limit asset for NavBridge.

Source: the WME Descartes crawl in the Decode_Waze repo
(`/Users/tungdl/Documents/Eink/Decode_Waze/vn_features`, 10,952 tiles, 2.5 GB).
Each tile's `segments.objects[]` carries `fwdMaxSpeed` / `revMaxSpeed` — the
real posted limit PER DIRECTION — plus `geometry` and `roadType`.

Why this layer exists (verified 2026-09-14):
  * HCMC: 70,780 segments, 67,651 (95.6%) carry a limit; nationwide ~70% of
    segments do (~1.7 M segments).
  * The app previously shipped only `waze_speed_limits.json` (49,942 POINTS,
    built from the mod's speed-limit map comments, types 12/13). On a real
    HCMC trip that point layer had ZERO hits within 200 m of the 308 GPS fixes,
    while this segment layer puts a limit within 20 m of 54% and within 200 m
    of 100%. So the app was guessing from the OSM road class while 1.7 M real
    posted limits sat on disk.
  * Cross-checked against the trip: same-street-name match agreed with Waze on
    Lũy Bán Bích (60), Trường Chinh (60), Ấp Bắc (50) and DISAGREED on Âu Cơ
    (Waze 50, our class table 60) — the segment layer is the better truth.

Output: a little-endian binary blob, because JSON would be ~190 MB nationwide
(vs ~22 MB packed):

    header (40 bytes)
      magic      4s   b'WZSG'
      version    u32  3
      nPoints    u32  total coordinate count across all segments
      nCoordB    u32  byte length of the varint coordinate stream
      nSegs      u32
      cellE4     u32  grid cell size in 1e-4 degrees (50 => 0.005 deg ~ 550 m)
      nStreets   u32  entries in the interned street-name table
      lat0e5     i32  bbox min lat * 1e5
      lng0e5     i32  bbox min lng * 1e5
      streetBlobB u32 byte length of the street-name blob

    offsets  (nSegs + 1) * u32   BYTE offset of each segment in the coord stream
    coords   nCoordB bytes       zigzag-varint lat/lng, 1e-5 deg:
                                 first point absolute, later points delta-coded
    fwd      nSegs * u8          km/h, 0 = unknown
    rev      nSegs * u8          km/h, 0 = unknown
    segStreet nSegs * u32        index into the street table, 0xFFFFFFFF = none
    segClass  nSegs * u8         roadType (bits 0-5) | separator (bit 7)
    streetOff (nStreets + 1) u32 BYTE offset of each name in the name blob
    names    streetBlobB bytes   UTF-8, NUL-terminated street names

v3 (2026-09-15) adds the street table. WME gives each segment
`primaryStreetID` (falling back to `streetIDs[0]`) and each street a `name`,
`englishName` and `signText` (the road number, e.g. "4036" -> Tỉnh lộ 4036),
plus `roadType` and `separator` (the divided-carriageway flag). Keeping only
geometry + limits is what made the app resolve the street NAME through
GraphHopper (a throttled, stateless nearest-edge query) while the LIMIT came
from this geometric layer, so the two desynced. With the name here, ONE lookup
answers "which street is this" and "what is the limit" at the same instant.
Also `separator` is the real divided-road signal that the 50-vs-60 built-up
rule wants, instead of inferring it from oneway && lanes >= 2.

Why varint: v1 stored 1.03 M segments / 4.37 M coordinates as int32 with a
shared node table = 49 MB. Delta+zigzag varints bring the same data to ~22 MB
because consecutive points of a Waze segment are metres apart (~2 bytes each)
and only each segment's first point needs a full absolute value (~7 bytes).

NOTE: 40-byte header (4s + 6 u32 + 2 i32 + 1 u32). The Dart loader in
lib/services/offline_speed_limits.dart hardcodes the same constant and the same
varint scheme — change both together.

Usage:
    python3 tools/signs/build_waze_segments.py                 # nationwide
    python3 tools/signs/build_waze_segments.py --hcmc           # HCMC tiles only (fast)
    python3 tools/signs/build_waze_segments.py --dir <tiledir>  # explicit tile dir
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import struct
import sys
from array import array

DEFAULT_CRAWL = '/Users/tungdl/Documents/Eink/Decode_Waze'
OUT = 'assets/offline_map/waze_segments.bin'
CELL_E4 = 50          # 0.005 deg ~ 550 m — a 3x3 query covers ~1.6 km
MIN_KMH, MAX_KMH = 5, 150


def tiles(args) -> list[str]:
    if args.dir:
        return sorted(glob.glob(os.path.join(args.dir, '*.json')))
    if args.hcmc:
        return sorted(glob.glob(os.path.join(DEFAULT_CRAWL, 'vn_hcmc', '*.json')))
    return sorted(glob.glob(os.path.join(DEFAULT_CRAWL, 'vn_features', '*.json')))


def put_varint(buf: bytearray, value: int) -> None:
    """Append a zigzag+LEB128 varint. Zigzag maps small negatives to small
    unsigned values, so a few-metres coordinate delta costs 2 bytes."""
    v = (value << 1) ^ (value >> 63) if value < 0 else (value << 1)
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            buf.append(b | 0x80)
        else:
            buf.append(b)
            return


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', help='directory of WME tile JSONs')
    ap.add_argument('--hcmc', action='store_true', help='use the HCMC tile set only')
    ap.add_argument('--out', default=OUT)
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    files = tiles(args)
    if not files:
        print('no tiles found', file=sys.stderr)
        return 1

    coords = bytearray()          # zigzag-varint lat/lng deltas
    offsets = array('I', [0])
    fwd = array('B')
    rev = array('B')
    # v3 street identity: one geometric lookup answers "which street" AND
    # "what limit", so the name and the limit can never come from different
    # sources at different times.
    street_index: dict[int, int] = {}   # WME street id -> interned index
    street_names: list[str] = []
    seg_street = array('I')             # per segment -> street_names index
    seg_class = array('B')              # roadType (bits 0-5) | separator (bit 7)
    no_street = 0
    no_street_name = 0

    seen: set[int] = set()
    total_tiles = 0
    skipped_dup = 0
    skipped_geom = 0
    skipped_speed = 0
    n_points = 0
    min_lat = min_lng = 1 << 30

    for path in files:
        try:
            with open(path, encoding='utf-8') as f:
                d = json.load(f)
        except Exception:
            continue
        total_tiles += 1
        # The streets table is per tile: id -> {name, englishName, signText}.
        streets_by_id = {
            str(o['id']): o
            for o in ((d.get('streets') or {}).get('objects') or [])
            if isinstance(o, dict) and 'id' in o
        }
        for s in (d.get('segments') or {}).get('objects') or []:
            sid = s.get('id')
            if sid is None or sid in seen:
                if sid is not None:
                    skipped_dup += 1
                continue
            f_kmh = s.get('fwdMaxSpeed') or 0
            r_kmh = s.get('revMaxSpeed') or 0
            if not (MIN_KMH <= f_kmh <= MAX_KMH or MIN_KMH <= r_kmh <= MAX_KMH):
                skipped_speed += 1
                continue
            g = (s.get('geometry') or {}).get('coordinates') or []
            if len(g) < 2:
                skipped_geom += 1
                continue
            # quantise to 1e-5 deg (~1.1 m) and drop consecutive duplicates
            pts: list[tuple[int, int]] = []
            for c in g:
                lat_e5 = int(round(c[1] * 1e5))
                lng_e5 = int(round(c[0] * 1e5))
                if pts and pts[-1] == (lat_e5, lng_e5):
                    continue
                pts.append((lat_e5, lng_e5))
            if len(pts) < 2:
                skipped_geom += 1
                continue
            prev_lat = prev_lng = 0
            for i, (p_lat, p_lng) in enumerate(pts):
                if i == 0:
                    put_varint(coords, p_lat)
                    put_varint(coords, p_lng)
                else:
                    put_varint(coords, p_lat - prev_lat)
                    put_varint(coords, p_lng - prev_lng)
                prev_lat, prev_lng = p_lat, p_lng
            offsets.append(len(coords))
            n_points += len(pts)
            for p_lat, p_lng in pts:
                if p_lat < min_lat:
                    min_lat = p_lat
                if p_lng < min_lng:
                    min_lng = p_lng
            fwd.append(f_kmh if MIN_KMH <= f_kmh <= MAX_KMH else 0)
            rev.append(r_kmh if MIN_KMH <= r_kmh <= MAX_KMH else 0)
            # --- street identity (v3) ---
            wst = s.get('primaryStreetID')
            if wst is None:
                ids = s.get('streetIDs') or []
                wst = ids[0] if ids else None
            idx = 0xFFFFFFFF
            if wst is not None:
                idx = street_index.get(wst, 0xFFFFFFFF)
                if idx == 0xFFFFFFFF:
                    st = streets_by_id.get(str(wst)) or {}
                    label = (st.get('name') or st.get('englishName')
                             or st.get('signText') or '').strip()
                    if label:
                        idx = len(street_names)
                        street_names.append(label)
                        street_index[wst] = idx
            if wst is None:
                no_street += 1
            elif idx == 0xFFFFFFFF:
                no_street_name += 1
            seg_street.append(idx)
            rt = s.get('roadType')
            rt = rt if isinstance(rt, int) and 0 <= rt <= 63 else 0
            seg_class.append(rt | (0x80 if s.get('separator') is True else 0))
            seen.add(sid)
        if not args.quiet and total_tiles % 250 == 0:
            print('  ... %d/%d tiles, %d segments' % (total_tiles, len(files), len(fwd)))

    n_segs = len(fwd)
    if n_segs == 0:
        print('no usable segments', file=sys.stderr)
        return 1

    # Interned street-name table: (nStreets + 1) u32 offsets + a UTF-8,
    # NUL-terminated blob. Interning matters because a busy road is split into
    # thousands of segments that all share one name.
    name_blob = bytearray()
    street_off = array('I', [0])
    for nm in street_names:
        name_blob += nm.encode('utf-8')
        name_blob.append(0)
        street_off.append(len(name_blob))
    n_streets = len(street_names)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'wb') as f:
        f.write(struct.pack('<4sIIIIIIiiI', b'WZSG', 3, n_points,
                            len(coords), n_segs, CELL_E4, n_streets,
                            min_lat, min_lng, len(name_blob)))
        offsets.tofile(f)
        f.write(coords)
        fwd.tofile(f)
        rev.tofile(f)
        seg_street.tofile(f)
        seg_class.tofile(f)
        street_off.tofile(f)
        f.write(name_blob)

    size = os.path.getsize(args.out)
    print()
    print('tiles read          : %d' % total_tiles)
    print('segments written    : %d' % n_segs)
    print('coordinates         : %d  (%.2f per segment)'
          % (n_points, n_points / max(n_segs, 1)))
    print('coord stream        : %.2f MB  (%.2f bytes per coordinate)'
          % (len(coords) / 1e6, len(coords) / max(n_points, 1)))
    print('skipped  duplicate  : %d' % skipped_dup)
    print('skipped  no geometry: %d' % skipped_geom)
    print('skipped  bad speed  : %d' % skipped_speed)
    print('output              : %s  (%.2f MB)' % (args.out, size / 1e6))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
