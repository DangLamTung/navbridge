#!/usr/bin/env python3
"""Compare NavBridge's TWO speed-limit datasets, point by point.

The app has two independent sources and lets the SIGN layer override the ROAD
layer. Nothing has ever compared them. This does.

  A  sign layer   assets/offline_map/vietnam_signs.json  (kind == "speed")
                  — adopted during nav, wins over the road layer.
  B  road layer   assets/offline_map/waze_segments.bin    (dense per-segment,
                    queried FIRST by speedLimitAt()) + waze_speed_limits.json
                    + vietmap_speed_limits.json (point fallbacks)
                  — this is the value the trip log records as `speedLimit`,
                    i.e. "the road's own limit" on the chip.

Output
  * coverage: how many A points have a B counterpart, and how close it is
  * head-to-head: A=60 vs B=50 → how many points
  * worst streets (street names come from the segment layer's v3 table)
  * the drive-relevant part: A points within --corridor-m of a recorded trip
  * docs/speed_sources_diff.html — a Leaflet map of every disagreement

Usage
    python3 tool/compare_speed_sources.py
    python3 tool/compare_speed_sources.py --trip "docs/trips/device/2026-09-18_172234_Chuyến_đi.json"
    python3 tool/compare_speed_sources.py --max-m 25 --map docs/speed_sources_diff.html
"""
from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
from collections import Counter, defaultdict

A = 'assets/offline_map/'
M_PER_DEG_LAT = 111320.0


# ---------------------------------------------------------------- segments --
def load_segments(path: str):
    """Parse WZSG v2/v3: [(points_e5, fwd, rev, street, road_class), ...]."""
    with open(path, 'rb') as fh:
        blob = fh.read()
    magic, ver, n_pts, n_coord_b, n_segs, cell_e4, n_streets, lat0, lng0, name_b = \
        struct.unpack_from('<4sIIIIIIiiI', blob, 0)
    if magic != b'WZSG':
        raise SystemExit(f'{path}: bad magic {magic!r}')
    header = 40 if ver >= 3 else 36
    off = header
    offsets = struct.unpack_from(f'<{n_segs + 1}I', blob, off)
    off += (n_segs + 1) * 4
    coord_base = off
    off += n_coord_b
    fwd = blob[off:off + n_segs]
    off += n_segs
    rev = blob[off:off + n_segs]
    off += n_segs
    streets = None
    classes = None
    if ver >= 3:
        seg_street_off = off
        off += n_segs * 4
        seg_class_off = off
        off += n_segs
        street_off_off = off
        off += (n_streets + 1) * 4
        names_off = off

        def name_at(i: int) -> str | None:
            if i == 0xFFFFFFFF:
                return None
            a = struct.unpack_from('<I', blob, street_off_off + i * 4)[0]
            z = struct.unpack_from('<I', blob, street_off_off + (i + 1) * 4)[0]
            raw = blob[names_off + a:names_off + z]
            return raw.split(b'\x00')[0].decode('utf-8', 'replace') or None

        street_idx = struct.unpack_from(f'<{n_segs}I', blob, seg_street_off)
        streets = [name_at(i) for i in street_idx]
        classes = blob[seg_class_off:seg_class_off + n_segs]

    segs = []
    for s in range(n_segs):
        a = coord_base + offsets[s]
        z = coord_base + offsets[s + 1]
        i = a
        lat = lng = 0
        pts = []
        while i < z:
            d_lat, i = _varint(blob, i)
            d_lng, i = _varint(blob, i)
            lat = d_lat if not pts else lat + d_lat
            lng = d_lng if not pts else lng + d_lng
            pts.append((lat / 1e5, lng / 1e5))
        segs.append({
            'pts': pts,
            'fwd': fwd[s],
            'rev': rev[s],
            'kmh': fwd[s] or rev[s] or 0,
            'street': streets[s] if streets else None,
            'class': (classes[s] & 0x3F) if classes else 0,
            'sep': bool(classes[s] & 0x80) if classes else False,
        })
    return segs, cell_e4


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


# ------------------------------------------------------------- point index --
class PointIndex:
    """Simple 0.002° grid over points carrying a km/h value."""

    CELL = 0.002

    def __init__(self, items):
        self.items = items
        self.grid = defaultdict(list)
        for idx, it in enumerate(items):
            self.grid[self._key(it['lat'], it['lng'])].append(idx)

    def _key(self, lat, lng):
        return (int(math.floor(lat / self.CELL)), int(math.floor(lng / self.CELL)))

    def nearest(self, lat, lng):
        gy, gx = self._key(lat, lng)
        best, best_d = None, float('inf')
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for idx in self.grid.get((gy + dy, gx + dx), ()):
                    it = self.items[idx]
                    d = math.hypot((it['lat'] - lat) * M_PER_DEG_LAT,
                                   (it['lng'] - lng) * M_PER_DEG_LAT
                                   * math.cos(math.radians(lat)))
                    if d < best_d:
                        best, best_d = it, d
        return best, best_d


class SegIndex:
    """0.005° grid: which segments touch a cell (bbox based)."""

    CELL = 0.005

    def __init__(self, segs):
        self.segs = segs
        self.grid = defaultdict(list)
        for idx, s in enumerate(segs):
            lats = [p[0] for p in s['pts']]
            lngs = [p[1] for p in s['pts']]
            if not lats:
                continue
            for gy in range(int(math.floor(min(lats) / self.CELL)),
                            int(math.floor(max(lats) / self.CELL)) + 1):
                for gx in range(int(math.floor(min(lngs) / self.CELL)),
                                int(math.floor(max(lngs) / self.CELL)) + 1):
                    self.grid[(gy, gx)].append(idx)

    def nearest(self, lat, lng, rings=1):
        gy = int(math.floor(lat / self.CELL))
        gx = int(math.floor(lng / self.CELL))
        best, best_d = None, float('inf')
        seen = set()
        for dy in range(-rings, rings + 1):
            for dx in range(-rings, rings + 1):
                for idx in self.grid.get((gy + dy, gx + dx), ()):
                    if idx in seen:
                        continue
                    seen.add(idx)
                    d = _dist_to_polyline(lat, lng, self.segs[idx]['pts'])
                    if d < best_d:
                        best, best_d = self.segs[idx], d
        return best, best_d


def _dist_to_polyline(lat, lng, pts) -> float:
    m_lng = M_PER_DEG_LAT * math.cos(math.radians(lat))
    best = float('inf')
    px, py = lng * m_lng, lat * M_PER_DEG_LAT
    for i in range(len(pts)):
        ax, ay = pts[i][1] * m_lng, pts[i][0] * M_PER_DEG_LAT
        if i + 1 < len(pts):
            bx, by = pts[i + 1][1] * m_lng, pts[i + 1][0] * M_PER_DEG_LAT
        else:
            bx, by = ax, ay
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
        cx, cy = ax + t * dx, ay + t * dy
        d = math.hypot(px - cx, py - cy)
        if d < best:
            best = d
    return best


def load_point_layer(path):
    if not os.path.exists(path):
        return []
    doc = json.load(open(path, encoding='utf-8'))
    return [{'lat': float(p['lat']), 'lng': float(p['lng']),
             'kmh': int(p.get('kmh') or 0), 'from': os.path.basename(path)}
            for p in doc.get('points', []) if p.get('kmh')]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--signs', default=A + 'vietnam_signs.json')
    ap.add_argument('--segments', default=A + 'waze_segments.bin')
    ap.add_argument('--points', nargs='*',
                    default=[A + 'waze_speed_limits.json',
                             A + 'vietmap_speed_limits.json'])
    ap.add_argument('--max-m', type=float, default=40.0,
                    help='a counterpart must be this close to count as "same spot"')
    ap.add_argument('--trip', default=None,
                    help='also report the sign points along a recorded drive')
    ap.add_argument('--corridor-m', type=float, default=200.0)
    ap.add_argument('--map', default='docs/speed_sources_diff.html')
    ap.add_argument('--top', type=int, default=25)
    args = ap.parse_args()

    print('loading sign layer (A)…')
    signs = [s for s in json.load(open(args.signs, encoding='utf-8'))['signs']
             if s.get('kind') == 'speed' and s.get('value')]
    print(f'  A: {len(signs)} speed points')

    print('loading road layer (B)…')
    segs, cell_e4 = load_segments(args.segments)
    seg_with_limit = sum(1 for s in segs if s['kmh'])
    print(f'  B: {len(segs)} waze segments ({seg_with_limit} with a limit, '
          f'{len(segs) - seg_with_limit} empty), cell {cell_e4}e-4')
    pts = []
    for p in args.points:
        layer = load_point_layer(p)
        print(f'     {os.path.basename(p)}: {len(layer)} points')
        pts += layer
    seg_index = SegIndex(segs)
    pt_index = PointIndex(pts)

    print(f'matching every A point to the nearest B within {args.max_m:.0f} m…')
    rows = []
    pairs = Counter()
    for s in signs:
        lat, lng = float(s['lat']), float(s['lng'])
        seg, seg_d = seg_index.nearest(lat, lng, rings=1)
        pt, pt_d = pt_index.nearest(lat, lng)
        seg_kmh = seg['kmh'] if seg and seg_d <= args.max_m else 0
        pt_kmh = pt['kmh'] if pt and pt_d <= args.max_m else 0
        road = seg_kmh or pt_kmh
        rows.append({
            'lat': lat, 'lng': lng, 'kmh': int(s['value']),
            'name': s.get('name') or '', 'src': s.get('source') or '',
            'seg_kmh': seg_kmh, 'seg_d': seg_d if seg else None,
            'seg_street': (seg or {}).get('street'),
            'seg_class': (seg or {}).get('class', 0),
            'seg_sep': (seg or {}).get('sep', False),
            'pt_kmh': pt_kmh, 'pt_d': pt_d if pt else None,
            'pt_from': (pt or {}).get('from'),
            'road': road,
        })
        if road:
            pairs[(int(s['value']), road)] += 1

    matched = [r for r in rows if r['road']]
    unmatched = [r for r in rows if not r['road']]
    agree = [r for r in matched if r['kmh'] == r['road']]
    disagree = [r for r in matched if r['kmh'] != r['road']]

    print(f'\n=== coverage (nearest B within {args.max_m:.0f} m) ===')
    print(f'  A points matched to a road-layer value : {len(matched)} '
          f'({100.0 * len(matched) / len(rows):.1f}%)')
    print(f'  A points with NO road-layer value near : {len(unmatched)} '
          f'({100.0 * len(unmatched) / len(rows):.1f}%)')
    print(f'     of those, nearest segment distance: '
          f'{_pct([r["seg_d"] for r in unmatched if r["seg_d"] is not None])}')
    print(f'\n=== agreement among matched points ===')
    print(f'  SAME value : {len(agree)} '
          f'({100.0 * len(agree) / max(1, len(matched)):.1f}% of matched)')
    print(f'  DIFFERENT  : {len(disagree)} '
          f'({100.0 * len(disagree) / max(1, len(matched)):.1f}% of matched)')

    print('\n=== head-to-head: sign layer value → road layer value (top 15) ===')
    print(f'  {"sign":>5} {"road":>5} {"points":>8}   effect on the driver')
    for (a, b), n in pairs.most_common(15):
        if a == b:
            continue
        verdict = ('LIMIT TOO HIGH' if a > b else 'LIMIT TOO LOW')
        print(f'  {a:>5} {b:>5} {n:>8}   {verdict}')

    print(f'\n=== worst streets by disagreement (top {args.top}) ===')
    by_street = Counter()
    for r in disagree:
        by_street[(r['seg_street'] or '(unnamed)',
                   r['seg_class'], r['kmh'], r['road'])] += 1
    for (street, cls, a, b), n in by_street.most_common(args.top):
        print(f'  {n:>5} points  {street:<28} class={cls:<2} '
              f'sign={a} road={b}')

    trip_rows = []
    if args.trip:
        trip_rows = _trip_report(args.trip, seg_index, pt_index, args)

    if args.map:
        _write_map(args.map, rows, disagree, unmatched, trip_rows, args)

    if trip_rows:
        print(f'\n=== along the recorded drive (±{args.corridor_m:.0f} m) ===')
        for r in trip_rows:
            flag = ('OK' if r['kmh'] == r['road'] else
                    'MISMATCH' if r['road'] else 'no-road-value')
            print(f'  fix {r["fix_i"]:>4} @{r["s_m"]:>5.0f} m  '
                  f'sign={r["kmh"]} road={r["road"] or "-"} '
                  f'({r["pt_from"] or "segments"}) '
                  f'street={r["seg_street"] or "?"}  {flag}')
    return 0


def _pct(vals):
    if not vals:
        return 'n/a'
    vals = sorted(vals)
    return (f'p25={vals[len(vals) // 4]:.0f} m '
            f'median={vals[len(vals) // 2]:.0f} m '
            f'p75={vals[3 * len(vals) // 4]:.0f} m')


def _trip_report(trip_path, seg_index, pt_index, args):
    """Sign points within the trip corridor, with their along-track distance."""
    doc = json.load(open(trip_path, encoding='utf-8'))
    fixes = []
    for loc in doc.get('locations', []):
        try:
            fixes.append((float(loc['latitudeE7']) / 1e7,
                          float(loc['longitudeE7']) / 1e7))
        except (KeyError, TypeError, ValueError):
            continue
    cum = [0.0]
    for i in range(1, len(fixes)):
        lat0, lng0 = fixes[i - 1]
        lat1, lng1 = fixes[i]
        cum.append(cum[-1] + math.hypot((lat1 - lat0) * M_PER_DEG_LAT,
                                        (lng1 - lng0) * M_PER_DEG_LAT
                                        * math.cos(math.radians(lat0))))
    signs = [s for s in json.load(open(args.signs, encoding='utf-8'))['signs']
             if s.get('kind') == 'speed' and s.get('value')]
    out = []
    for s in signs:
        lat, lng = float(s['lat']), float(s['lng'])
        best_i, best_d = None, float('inf')
        for i, (fl, fg) in enumerate(fixes):
            d = math.hypot((fl - lat) * M_PER_DEG_LAT,
                           (fg - lng) * M_PER_DEG_LAT * math.cos(math.radians(lat)))
            if d < best_d:
                best_i, best_d = i, d
                if d < 5:
                    break
        if best_d > args.corridor_m:
            continue
        seg, seg_d = seg_index.nearest(lat, lng)
        pt, pt_d = pt_index.nearest(lat, lng)
        seg_kmh = seg['kmh'] if seg and seg_d <= args.max_m else 0
        pt_kmh = pt['kmh'] if pt and pt_d <= args.max_m else 0
        out.append({
            'fix_i': best_i, 's_m': cum[best_i], 'lat': lat, 'lng': lng,
            'kmh': int(s['value']), 'road': seg_kmh or pt_kmh,
            'off_m': best_d, 'seg_street': (seg or {}).get('street'),
            'pt_from': (pt or {}).get('from') if pt_kmh else
                       ('segments' if seg_kmh else None),
        })
    return sorted(out, key=lambda r: r['s_m'])


def _write_map(path, rows, disagree, unmatched, trip_rows, args):
    import html
    keep = []
    for r in rows:
        if r in disagree or r in unmatched:
            keep.append(r)
        elif len(keep) < 4000:
            keep.append(r)
    features = []
    for r in keep[:20000]:
        state = ('agree' if r['road'] and r['kmh'] == r['road'] else
                 'mismatch' if r['road'] else 'nohit')
        features.append({
            'lat': round(r['lat'], 6), 'lng': round(r['lng'], 6),
            'sign': r['kmh'], 'road': r['road'], 'state': state,
            'street': r['seg_street'] or '', 'from': r['pt_from'] or 'segments',
            'd': round(r['seg_d'], 1) if r['seg_d'] is not None else None,
        })
    trips = [{'lat': round(r['lat'], 6), 'lng': round(r['lng'], 6),
              'sign': r['kmh'], 'road': r['road'], 's_m': round(r['s_m'])}
             for r in trip_rows]
    # Header numbers are the TRUE totals; FEAT may be a capped subset.
    n_mismatch = sum(1 for r in rows if r['road'] and r['kmh'] != r['road'])
    n_nohit = sum(1 for r in rows if not r['road'])
    n_agree = sum(1 for r in rows if r['road'] and r['kmh'] == r['road'])
    counts = Counter(f['state'] for f in features)  # noqa: F841 — kept for debug
    body = f"""<!doctype html><meta charset="utf-8">
<title>NavBridge speed sources — sign layer vs road layer</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
 body{{margin:0;font:13px/1.45 -apple-system,Segoe UI,Roboto,sans-serif;background:#0f1216;color:#e7ecf2}}
 #head{{padding:10px 14px;background:#161b22;border-bottom:1px solid #2a323d}}
 #head b{{font-size:15px}}
 #stats{{display:flex;gap:18px;flex-wrap:wrap;margin-top:6px}}
 .k{{font-size:20px;font-weight:600}} .lbl{{color:#93a1b1;font-size:11px;text-transform:uppercase}}
 #map{{position:absolute;top:96px;bottom:0;left:0;right:0}}
 .dot{{border-radius:50%}}
</style>
<div id="head">
  <b>Speed-limit sources compared</b>
  <span style="color:#93a1b1">A = <code>vietnam_signs.json</code> speed points (what nav adopts, wins over the road) ·
  B = waze segments + waze/vietmap point layers (what the chip/log calls the road's limit) ·
  a point is "matched" if a B value sits within {args.max_m:.0f} m</span>
  <div id="stats">
    <div><div class="k">{len(rows)}</div><div class="lbl">A points</div></div>
    <div><div class="k" style="color:#e5534b">{n_mismatch}</div><div class="lbl">disagree (red)</div></div>
    <div><div class="k" style="color:#d29922">{n_nohit}</div><div class="lbl">no road value near (amber)</div></div>
    <div><div class="k" style="color:#3fb950">{n_agree}</div><div class="lbl">agree (green)</div></div>
    <div><div class="k" style="color:#58a6ff">{len(trips)}</div><div class="lbl">on the 09-18 drive</div></div>
    <div style="color:#93a1b1;max-width:280px">markers are drawn for every
disagreement plus a sample of the rest ({len(features)} of {len(rows)} points)</div>
  </div>
</div>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const FEAT = {json.dumps(features, separators=(',', ':'))};
const TRIP = {json.dumps(trips, separators=(',', ':'))};
const map = L.map('map').setView([10.7769, 106.6500], 13);
L.tileLayer('https://{{s}}.tile.openstreetmap.org/{{z}}/{{x}}/{{y}}.png',
  {{maxZoom:19, attribution:'© OpenStreetMap'}}).addTo(map);
const COL = {{agree:'#3fb950', mismatch:'#e5534b', nohit:'#d29922'}};
for (const f of FEAT) {{
  const m = L.circleMarker([f.lat, f.lng], {{
    radius: f.state === 'agree' ? 3 : 5, color: COL[f.state],
    fillColor: COL[f.state], fillOpacity: f.state === 'agree' ? 0.35 : 0.9,
    weight: 1}});
  m.bindPopup(
    `<b>sign layer (A): ${{f.sign}} km/h</b><br>` +
    `road layer (B): ${{f.road || 'none within {args.max_m:.0f} m'}}` +
    (f.from ? ` <span style="color:#888">(${{f.from}})</span>` : '') + `<br>` +
    `street: ${{f.street || '—'}}<br>` +
    (f.d !== null ? `nearest segment: ${{f.d}} m` : '') +
    (f.state === 'mismatch'
      ? `<br><span style="color:#c00">the app rides at ${{f.sign}}, the road says ${{f.road}}</span>`
      : ''));
  m.addTo(map);
}}
if (TRIP.length) {{
  L.polyline(TRIP.map(t => [t.lat, t.lng]), {{color:'#58a6ff', weight:2,
    opacity:0.7, dashArray:'4 4'}}).addTo(map);
  for (const t of TRIP) {{
    L.circleMarker([t.lat, t.lng], {{radius:4, color:'#58a6ff', weight:2,
      fillColor:'#0f1216', fillOpacity:1}})
      .bindPopup(`on the drive @${{t.s_m}} m<br>sign=${{t.sign}} km/h` +
                 `<br>road=${{t.road || '—'}}`).addTo(map);
  }}
  map.fitBounds(L.latLngBounds(TRIP.map(t => [t.lat, t.lng])).pad(0.25));
}}
</script>
"""
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(body)
    print(f'\nwrote {path} ({os.path.getsize(path) / 1024:.0f} KB, '
          f'{len(features)} points)')


if __name__ == '__main__':
    sys.exit(main())
