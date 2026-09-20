#!/usr/bin/env python3
"""Render the Waze per-SEGMENT speed-limit asset into a standalone HTML viewer.

Reads `assets/offline_map/waze_segments.bin` (see build_waze_segments.py for the
format) and writes a self-contained Leaflet page: every segment drawn as a
polyline coloured by its posted limit, with the segment's fwd/rev values in a
popup. Optionally overlays a recorded trip (route + GPS fixes + announcements)
so the limits can be checked against a real drive.

Usage:
    python3 tools/signs/visualize_waze_segments.py                 # HCMC + trip
    python3 tools/signs/visualize_waze_segments.py --bbox 10.75,106.60,10.82,106.68
    python3 tools/signs/visualize_waze_segments.py --all           # whole file
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys

DEFAULT_BIN = 'assets/offline_map/waze_segments.bin'
DEFAULT_TRIP = 'docs/trips/2026-09-14_084019_Chuyến_đi.json'
DEFAULT_OUT = 'docs/waze_segments_view.html'

# limit -> colour, low to high
COLOURS = [
    (20, '#7b1fa2'), (30, '#512da8'), (40, '#1976d2'), (50, '#2e7d32'),
    (60, '#f9a825'), (70, '#ef6c00'), (80, '#e64a19'), (90, '#c62828'),
    (100, '#8e0000'), (120, '#111111'),
]


def colour_for(kmh: int) -> str:
    c = '#9e9e9e'
    for v, col in COLOURS:
        if kmh >= v:
            c = col
    return c


def read_segments(path: str):
    blob = open(path, 'rb').read()
    magic, ver, nPoints, nCoordB, nSegs, cellE4, _, lat0, lng0 = struct.unpack_from(
        '<4sIIIIIIii', blob, 0)
    if magic != b'WZSG' or ver != 2:
        raise SystemExit('unsupported asset %r v%d' % (magic, ver))
    offsets = struct.unpack_from('<%dI' % (nSegs + 1), blob, 36)
    coord_base = 36 + (nSegs + 1) * 4
    fwd_base = coord_base + nCoordB

    def decode(s):
        i = coord_base + offsets[s]
        end = coord_base + offsets[s + 1]
        pts = []
        lat = lng = 0
        while i < end:
            v = shift = 0
            while True:
                b = blob[i]; i += 1
                v |= (b & 0x7F) << shift
                if b < 0x80:
                    break
                shift += 7
            dlat = (v >> 1) ^ -(v & 1)
            v = shift = 0
            while True:
                b = blob[i]; i += 1
                v |= (b & 0x7F) << shift
                if b < 0x80:
                    break
                shift += 7
            dlng = (v >> 1) ^ -(v & 1)
            lat = dlat if not pts else lat + dlat
            lng = dlng if not pts else lng + dlng
            pts.append((lat / 1e5, lng / 1e5))
        return pts

    return blob, nSegs, offsets, coord_base, fwd_base, decode


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default=DEFAULT_BIN)
    ap.add_argument('--trip', default=DEFAULT_TRIP)
    ap.add_argument('--out', default=DEFAULT_OUT)
    ap.add_argument('--bbox', help='minLat,minLng,maxLat,maxLng (default: trip area)')
    ap.add_argument('--all', action='store_true', help='include every segment')
    ap.add_argument('--max-segments', type=int, default=120000)
    args = ap.parse_args()

    blob, nSegs, offsets, coord_base, fwd_base, decode = read_segments(args.bin)
    print('asset: %d segments' % nSegs)

    trip = None
    if args.trip and os.path.exists(args.trip):
        trip = json.load(open(args.trip, encoding='utf-8'))

    if args.all:
        box = None
    elif args.bbox:
        a = [float(v) for v in args.bbox.split(',')]
        box = (a[0], a[1], a[2], a[3])
    else:
        # derive from the trip, with a ~2 km margin
        lats = [l['latitudeE7'] / 1e7 for l in trip['locations']]
        lngs = [l['longitudeE7'] / 1e7 for l in trip['locations']]
        box = (min(lats) - 0.02, min(lngs) - 0.02, max(lats) + 0.02, max(lngs) + 0.02)
    print(f'box: {box if box else "ALL"}')

    out = []
    fwd = blob[fwd_base:fwd_base + nSegs]
    rev = blob[fwd_base + nSegs:fwd_base + 2 * nSegs]
    # quick reject using the first point only (segments are short)
    first_pt = []
    for s in range(nSegs):
        i = coord_base + offsets[s]
        v = shift = 0
        while True:
            b = blob[i]; i += 1
            v |= (b & 0x7F) << shift
            if b < 0x80:
                break
            shift += 7
        lat = ((v >> 1) ^ -(v & 1)) / 1e5
        v = shift = 0
        while True:
            b = blob[i]; i += 1
            v |= (b & 0x7F) << shift
            if b < 0x80:
                break
            shift += 7
        lng = ((v >> 1) ^ -(v & 1)) / 1e5
        first_pt.append((lat, lng))

    for s in range(nSegs):
        la, ln = first_pt[s]
        if box and not (box[0] <= la <= box[2] and box[1] <= ln <= box[3]):
            continue
        f, r = fwd[s], rev[s]
        if not f and not r:
            continue
        pts = decode(s)
        if len(pts) < 2:
            continue
        out.append({
            'p': [[round(x, 5), round(y, 5)] for x, y in pts],
            'f': f, 'r': r,
        })
        if len(out) >= args.max_segments:
            print('hit --max-segments, truncating')
            break

    print('segments rendered: %d' % len(out))

    trip_js = 'null'
    if trip:
        locs = trip['locations']
        trip_js = json.dumps({
            'route': [[round(l['latitudeE7'] / 1e7, 5), round(l['longitudeE7'] / 1e7, 5)]
                      for l in locs],
            'ann': [{'t': a['time'][11:19], 'k': a['kind'], 'x': a['text'],
                     'lat': round(a['lat'], 5), 'lng': round(a['lng'], 5)}
                    for a in trip.get('announcements', [])],
        }, ensure_ascii=False)

    legend = ''.join(
        '<label class="lg"><input type="checkbox" class="lim" value="%d" checked>'
        '<i style="background:%s"></i>%d km/h</label>' % (v, c, v)
        for v, c in COLOURS
    ) + ('<label class="lg"><input type="checkbox" class="lim" value="-1" checked>'
         '<i style="background:#9e9e9e"></i>&lt; 20</label>')

    html = TEMPLATE.replace('__SEGMENTS__', json.dumps(out, separators=(',', ':')))
    html = html.replace('__TRIP__', trip_js)
    html = html.replace('__LEGEND__', legend)
    html = html.replace('__COLOURS__', json.dumps({str(v): c for v, c in COLOURS}))
    html = html.replace('__COUNT__', str(len(out)))
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(html)
    print('wrote %s (%.2f MB)' % (args.out, os.path.getsize(args.out) / 1e6))
    return 0


TEMPLATE = r"""<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NavBridge — Waze per-segment speed limits</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
  html,body{margin:0;height:100%;font:13px/1.4 -apple-system,Roboto,Segoe UI,sans-serif}
  #map{position:absolute;inset:0}
  #panel{position:absolute;top:10px;right:10px;z-index:1000;background:#fff;
         border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.3);padding:10px 12px;
         max-width:250px}
  #panel h3{margin:0 0 6px;font-size:13px}
  .lg{display:flex;align-items:center;gap:6px;padding:1px 0;cursor:pointer}
  .lg i{width:16px;height:5px;border-radius:2px;display:inline-block}
  #panel hr{border:0;border-top:1px solid #eee;margin:8px 0}
  .hint{color:#666;font-size:11px}
  #title{position:absolute;top:10px;left:52px;z-index:1000;background:rgba(255,255,255,.94);
         padding:6px 10px;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.25)}
  #title b{font-size:13px}
  #title span{color:#666;font-size:11px;display:block}
  .pop b{font-size:14px}
  .pop table{border-collapse:collapse;font-size:12px}
  .pop td{padding:1px 6px 1px 0}
</style>
</head>
<body>
<div id="map"></div>
<div id="title"><b>Waze WME per-segment speed limits</b>
  <span>__COUNT__ segments · click a line for its fwd/rev limit</span></div>
<div id="panel">
  <h3>Posted limit</h3>
  __LEGEND__
  <hr>
  <label class="lg"><input type="checkbox" id="onlyDiff"> only fwd &ne; rev</label>
  <label class="lg"><input type="checkbox" id="showTrip" checked> show trip route</label>
  <hr>
  <div class="hint" id="stat"></div>
</div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const SEGS = __SEGMENTS__;
const TRIP = __TRIP__;
const COLOURS = __COLOURS__;
function colour(f,r){
  const v = Math.max(f||0, r||0);
  let c = '#9e9e9e';
  for (const k of Object.keys(COLOURS).map(Number).sort((a,b)=>a-b)) {
    if (v >= k) c = COLOURS[k];
  }
  return c;
}
const map = L.map('map', {preferCanvas:true}).setView([10.7946,106.6385], 15);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom:19, attribution:'© OpenStreetMap'}).addTo(map);

const layers = [];
let layersByLimit = {};
for (const s of SEGS){
  const v = Math.max(s.f||0, s.r||0);
  const bucket = v < 20 ? -1 : (Object.keys(COLOURS).map(Number)
      .filter(k=>v>=k).sort((a,b)=>b-a)[0] ?? -1);
  const pl = L.polyline(s.p, {color: colour(s.f,s.r), weight: 4, opacity:.85});
  let len = 0;
  for (let i=1;i<s.p.length;i++){
    const dy=(s.p[i][0]-s.p[i-1][0])*111320;
    const dx=(s.p[i][1]-s.p[i-1][1])*111320*Math.cos(s.p[i][0]*Math.PI/180);
    len += Math.hypot(dx,dy);
  }
  pl.bindPopup(`<div class="pop"><b>${Math.max(s.f||0,s.r||0)} km/h</b>
    <table>
      <tr><td>chiều thuận (fwd)</td><td>${s.f||'—'}</td></tr>
      <tr><td>chiều ngược (rev)</td><td>${s.r||'—'}</td></tr>
      <tr><td>dài</td><td>${len.toFixed(0)} m</td></tr>
      <tr><td>điểm</td><td>${s.p.length}</td></tr>
    </table></div>`);
  pl._lim = bucket; pl._diff = (s.f!==s.r);
  layers.push(pl);
  (layersByLimit[bucket] ||= []).push(pl);
}
const group = L.layerGroup(layers).addTo(map);

let tripLayer = null;
function drawTrip(){
  if (tripLayer){ map.removeLayer(tripLayer); tripLayer=null; }
  if (!TRIP || !document.getElementById('showTrip').checked) return;
  const g = L.layerGroup();
  L.polyline(TRIP.route, {color:'#1565c0', weight:3, dashArray:'6,4', opacity:.9}).addTo(g);
  for (const a of TRIP.ann){
    L.circleMarker([a.lat,a.lng], {radius:5, color:'#fff', weight:1,
      fillColor: a.k==='maneuver'?'#00bcd4': a.k==='camera'?'#ff5722':'#4caf50',
      fillOpacity:.95}).bindPopup(`<b>${a.t}</b><br>${a.k}<br>${a.x}`).addTo(g);
  }
  tripLayer = g.addTo(map);
}
drawTrip();

function apply(){
  const on = new Set([...document.querySelectorAll('.lim:checked')].map(e=>+e.value));
  const onlyDiff = document.getElementById('onlyDiff').checked;
  let shown=0;
  for (const l of layers){
    const vis = on.has(l._lim) && (!onlyDiff || l._diff);
    if (vis){ if(!group.hasLayer(l)) group.addLayer(l); shown++; }
    else if (group.hasLayer(l)) group.removeLayer(l);
  }
  document.getElementById('stat').textContent =
    `${shown} / ${layers.length} segments shown`;
}
document.querySelectorAll('.lim, #onlyDiff').forEach(e=>e.addEventListener('change', apply));
document.getElementById('showTrip').addEventListener('change', drawTrip);
apply();

if (TRIP && TRIP.route.length){
  map.fitBounds(L.latLngBounds(TRIP.route).pad(0.35));
}
</script>
</body>
</html>
"""

if __name__ == '__main__':
    raise SystemExit(main())
