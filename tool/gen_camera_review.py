#!/usr/bin/env python3
"""Render docs/cameras_kiemtra_review.html: the geocoded camera points on a map.

Eyeballing the coordinates is the only cheap way to catch a geocoder lying —
a bad batch shows up as pins in the sea or in the wrong district, which no
automated check catches.

    python3 tool/gen_camera_review.py [--src tool/data/dongnai_google.json]
"""
import argparse
import json
import math

ap = argparse.ArgumentParser()
ap.add_argument('--src', default='tool/data/dongnai_google.json')
ap.add_argument('--out', default='docs/cameras_kiemtra_review.html')
a = ap.parse_args()

rows = json.load(open(a.src, encoding='utf-8'))
pts = [{'n': r['name'], 'a': r.get('formatted_address', ''),
        'lat': r['lat'], 'lng': r['lng'], 'p': r['precision'],
        'd': r['district'], 'f': r['focus'], 'c': r.get('code') or '',
        'lt': r.get('location_type', '')} for r in rows]

lat0 = sum(p['lat'] for p in pts) / len(pts) if pts else 11.5
lng0 = sum(p['lng'] for p in pts) / len(pts) if pts else 107.0

html = """<!DOCTYPE html>
<html lang="vi"><head><meta charset="utf-8">
<title>Camera phạt nguội — review toạ độ</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
 body{margin:0;font:13px/1.45 system-ui,-apple-system,sans-serif}
 #map{position:absolute;inset:0;top:52px}
 header{height:52px;display:flex;align-items:center;gap:14px;padding:0 12px;
        background:#111;color:#eee;position:relative;z-index:500}
 header b{font-size:15px}
 .key{display:flex;align-items:center;gap:5px}
 .dot{width:11px;height:11px;border-radius:50%%;display:inline-block}
 .pin{width:11px;height:11px;border:2px solid #fff;border-radius:50%%}
 table{border-collapse:collapse;font-size:12px}
 td{padding:1px 5px;vertical-align:top}
 .mono{font-family:ui-monospace,monospace}
</style></head><body>
<header>
  <b>%d điểm</b>
  <span class="key"><span class="dot" style="background:#137333"></span>
    precise (%d)</span>
  <span class="key"><span class="dot" style="background:#D97706"></span>
    district — sai số ~3 km (%d)</span>
  <span style="opacity:.7">bấm pin để xem địa chỉ gốc</span>
</header>
<div id="map"></div>
<script>
const PTS = %s;
const map = L.map('map').setView([%f, %f], 9);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom:19, attribution:'&copy; OpenStreetMap'}).addTo(map);
const COL = {precise:'#137333', district:'#D97706'};
PTS.forEach(p => {
  const c = COL[p.p] || '#666';
  const m = L.circleMarker([p.lat, p.lng],
    {radius: p.p==='precise'?6:5, color:'#fff', weight:1.5,
     fillColor:c, fillOpacity:.95}).addTo(map);
  m.bindPopup(`<table>
    <tr><td>địa chỉ gốc</td><td><b>${p.n}</b></td></tr>
    <tr><td>Google trả</td><td>${p.a||'—'}</td></tr>
    <tr><td>toạ độ</td><td class="mono">${p.lat.toFixed(5)}, ${p.lng.toFixed(5)}</td></tr>
    <tr><td>độ chính xác</td><td>${p.p} / ${p.lt}</td></tr>
    <tr><td>tỉnh (polygon)</td><td>${p.d}</td></tr>
    <tr><td>loại vi phạm</td><td>${p.f} ${p.c?'· '+p.c:''}</td></tr>
    </table>`);
});
</script></body></html>
""" % (len(pts), sum(1 for p in pts if p['p'] == 'precise'),
       sum(1 for p in pts if p['p'] == 'district'),
       json.dumps(pts, ensure_ascii=False), lat0, lng0)

open(a.out, 'w', encoding='utf-8').write(html)
print(f'{a.out}: {len(pts)} points, centre {lat0:.3f},{lng0:.3f}')
