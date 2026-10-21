#!/usr/bin/env python3
"""Render EVERY camera in the shipped DB onto one page.

31,979 points is far past what SVG markers can take, so this uses Leaflet's
canvas renderer and a per-source layer you can toggle. The point of the page is
to see the difference between the 23k grey VietMap dots (position, no meaning)
and the red `kiemtraphatnguoi` points (meaning, geocoded position).

    python3 tool/gen_camera_map.py [--db assets/offline_map/vietnam_cameras.json]
"""
import argparse
import collections
import json

ap = argparse.ArgumentParser()
ap.add_argument('--db', default='assets/offline_map/vietnam_cameras.json')
ap.add_argument('--out', default='docs/cameras_all.html')
a = ap.parse_args()

db = json.load(open(a.db, encoding='utf-8'))
cams = db['cameras']

# draw order matters: the noisy surveillance layer goes down first so the
# meaningful points end up on top
ORDER = ['vietmap', 'waze', 'osm', 'police', 'kiemtraphatnguoi']
COLOR = {'vietmap': '#9ca3af', 'waze': '#2563eb', 'osm': '#a855f7',
         'police': '#16a34a', 'kiemtraphatnguoi': '#dc2626'}
LABEL = {'vietmap': 'VietMap (giám sát, vô danh)', 'waze': 'Waze',
         'osm': 'OSM', 'police': 'CSGT (cũ)',
         'kiemtraphatnguoi': 'CSGT kiemtraphatnguoi (mới geocode)'}

by_src = collections.Counter(c.get('source', 'osm') for c in cams)
rows = []
for c in cams:
    rows.append([
        round(c['lat'], 5), round(c['lng'], 5), c.get('source', 'osm'),
        c.get('focus', ''), c.get('type') or '',
        (c.get('name') or '')[:70], c.get('district') or '',
        c.get('precision') or '',
    ])
# keep leaflet draw order stable without a 32k sort per layer group
rows.sort(key=lambda r: ORDER.index(r[2]) if r[2] in ORDER else 99)

legend = ''.join(
    f'<label class="key"><input type="checkbox" data-src="{s}" checked>'
    f'<span class="dot" style="background:{COLOR[s]}"></span>{LABEL[s]} '
    f'<b>{by_src.get(s, 0):,}</b></label>'
    for s in ORDER)

html = """<!DOCTYPE html>
<html lang="vi"><head><meta charset="utf-8">
<title>Tất cả camera — %d điểm</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
 body{margin:0;font:12px/1.4 system-ui,-apple-system,sans-serif}
 #map{position:absolute;inset:0;top:66px}
 header{height:66px;display:flex;flex-wrap:wrap;align-items:center;gap:12px;
        padding:6px 12px;background:#111;color:#eee;position:relative;z-index:500}
 header b.tot{font-size:15px}
 .key{display:flex;align-items:center;gap:5px;cursor:pointer;user-select:none}
 .dot{width:10px;height:10px;border-radius:50%%;display:inline-block;
      border:1px solid #fff2}
 table{border-collapse:collapse;font-size:12px}
 td{padding:1px 5px;vertical-align:top}
 .mono{font-family:ui-monospace,monospace}
</style></head><body>
<header>
  <b class="tot">%d camera</b>
  <span style="opacity:.6">(DB v%s, %s)</span>
  %s
  <span id="shown" style="margin-left:auto;opacity:.8"></span>
</header>
<div id="map"></div>
<script>
const ROWS = %s;
const COLOR = %s;
const map = L.map('map', {preferCanvas: true}).setView([16.2, 106.8], 6);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom:19, attribution:'&copy; OpenStreetMap'}).addTo(map);

const layers = {};
const groups = {};
ROWS.forEach(r => (groups[r[2]] = groups[r[2]] || []).push(r));
Object.keys(groups).forEach(src => {
  const g = L.layerGroup();
  const col = COLOR[src] || '#666';
  groups[src].forEach(r => {
    const m = L.circleMarker([r[0], r[1]], {
      radius: src === 'kiemtraphatnguoi' ? 4 : 2.2,
      stroke: false, fillColor: col,
      fillOpacity: src === 'vietmap' ? 0.55 : 0.9});
    m.bindPopup(`<table>
      <tr><td>nguồn</td><td><b>${src}</b></td></tr>
      <tr><td>tên/địa chỉ</td><td>${r[5] || '—'}</td></tr>
      <tr><td>loại</td><td>${r[3]} ${r[4] ? '· ' + r[4] : ''}</td></tr>
      <tr><td>tỉnh/quận</td><td>${r[6] || '—'}</td></tr>
      ${r[7] ? '<tr><td>độ chính xác</td><td>' + r[7] + '</td></tr>' : ''}
      <tr><td>toạ độ</td><td class="mono">${r[0]}, ${r[1]}</td></tr>
    </table>`);
    g.addLayer(m);
  });
  layers[src] = g;
  g.addTo(map);
});

function tally() {
  let n = 0;
  Object.keys(layers).forEach(s => { if (map.hasLayer(layers[s])) n += groups[s].length; });
  document.getElementById('shown').textContent = 'đang hiện ' + n.toLocaleString();
}
document.querySelectorAll('input[data-src]').forEach(cb => {
  cb.addEventListener('change', () => {
    const l = layers[cb.dataset.src];
    if (!l) return;
    cb.checked ? map.addLayer(l) : map.removeLayer(l);
    tally();
  });
});
tally();
</script></body></html>
""" % (len(rows), len(rows), db.get('version', '?'), db.get('generated', ''),
       legend, json.dumps(rows, ensure_ascii=False),
       json.dumps(COLOR))

open(a.out, 'w', encoding='utf-8').write(html)
print(f'{a.out}: {len(rows)} cameras, '
      + ', '.join(f'{k}={v}' for k, v in by_src.most_common()))
