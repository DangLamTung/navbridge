#!/usr/bin/env python3
"""Visualise the speed-limit chain of a recorded trip, per fix.

Every GPS fix is classified by comparing the three numbers that matter:

  class  the statutory default for the vehicle from the OSM/graph road class
         (a motorbike is 60 on primary/secondary/tertiary, 50 on residential)
  waze   the posted limit on the Waze/WME segment under the car
  chip   what the app DISPLAYED (`limitEffective` + `limitSource`); for trips
         recorded before those fields existed, the road-layer `speedLimit`

Colouring on the map:
  green   chip == waze                                  (correct)
  orange  no waze value here — chip fell back to class  (expected)
  red     waze had a value and the chip disagreed       (the bug we hunt)

Usage:
    python3 tool/limit_audit.py [trip.json] [-o docs/limit_audit.html]
    (no trip -> newest under docs/trips/device)
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_truth as T  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEGS = os.path.join(REPO, 'assets/offline_map/waze_segments.bin')


def nearby_segments(rows, segs, radius_m=45.0, cap=4000):
    """Every Waze segment within [radius_m] of the driven track.

    The layer is what the app is supposed to obey, so drawing it (value-coded,
    dashed) under the track is what makes a "chip 60 / layer 50" row readable:
    the driver sees which street's segment carries which posted value.
    """
    from waze_segments import CELL_DEG
    out = {}
    for r in rows[::2]:
        cy = int(math.floor(r['lat'] / CELL_DEG))
        cx = int(math.floor(r['lng'] / CELL_DEG))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for s in segs.grid.get((cy + dy, cx + dx), ()):
                    if s in out:
                        continue
                    pts = segs.pts[s]
                    if len(pts) < 2:
                        continue
                    if min(T.meters((r['lat'], r['lng']), p)
                           for p in pts) > radius_m:
                        continue
                    out[s] = {
                        'pts': [[round(p[0], 6), round(p[1], 6)] for p in pts],
                        'fwd': segs.fwd[s], 'rev': segs.rev[s],
                        'street': segs.street(s) or '',
                    }
                    if len(out) >= cap:
                        return out
    return out


def rolling_runs(rows, key):
    """Contiguous runs of the same `key(row)` value (for the episode table)."""
    out = []
    for r in rows:
        if out and out[-1]['k'] == key(r):
            out[-1]['rows'].append(r)
        else:
            out.append({'k': key(r), 'rows': [r]})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('trip', nargs='?')
    ap.add_argument('-o', '--out', default=os.path.join(REPO,
                                                       'docs/limit_audit.html'))
    ap.add_argument('--vehicle', default='motorbike')
    args = ap.parse_args()

    if not args.trip:
        cands = sorted(glob.glob(os.path.join(REPO, 'docs/trips/device/*.json')))
        # A real drive, not an 8-fix fragment: newest by name (the trips are
        # named YYYY-MM-DD_HHMMSS) among those with enough fixes to be useful.
        best, best_n = None, 0
        for c in reversed(cands):
            try:
                with open(c, encoding='utf-8') as fh:
                    k = len(json.load(fh).get('locations') or [])
            except Exception:
                continue
            if k >= 200:
                best = c
                break
            if k > best_n:
                best, best_n = c, k
        if not best:
            print('no trips found')
            return 1
        args.trip = best

    with open(args.trip, encoding='utf-8') as fh:
        doc = json.load(fh)
    segs = T.Segments(SEGS)

    rows = []
    for e in doc.get('locations') or []:
        if not e.get('latitudeE7'):
            continue
        lat, lng = e['latitudeE7'] / 1e7, e['longitudeE7'] / 1e7
        h = e.get('heading')
        kmh = segs.query(lat, lng, h if isinstance(h, (int, float)) else None,
                         25)[0]
        hw = e.get('highway') or ''
        cls = T.effective_limit(hw or 'unclassified', args.vehicle,
                                tagged_kmh=0)
        chip = e.get('limitEffective')
        src = e.get('limitSource') or ('' if chip is not None else 'road(legacy)')
        if chip is None:
            chip = e.get('speedLimit')
        if not chip:
            state = 'none'
        elif not kmh:
            state = 'nowaze'
        elif chip == kmh:
            state = 'ok'
        elif chip == cls:
            state = 'class'
        else:
            state = 'bad'
        rows.append({
            't': int(e.get('timestampMs') or 0), 'lat': lat, 'lng': lng,
            'v': (e.get('velocity') or 0) * 3.6, 'acc': e.get('accuracy'),
            'street': e.get('street') or '', 'hw': hw,
            'road': e.get('speedLimit'), 'cls': cls, 'waze': kmh,
            'chip': chip, 'src': src, 'state': state,
        })
    if not rows:
        print('no fixes with a position')
        return 1

    counts = {}
    for r in rows:
        counts[r['state']] = counts.get(r['state'], 0) + 1
    n = len(rows)
    t0 = rows[0]['t']

    # Disagreement episodes: consecutive fixes with the same (street, chip, waze)
    # where a waze value existed and the chip differed.
    eps = []
    for run in rolling_runs(rows, lambda r: (r['state'], r['street'],
                                             r['chip'], r['waze'])):
        if run['k'][0] not in ('bad', 'class'):
            continue
        rs = run['rows']
        eps.append({
            'state': run['k'][0], 'street': rs[0]['street'],
            'hw': rs[0]['hw'], 'cls': rs[0]['cls'],
            'chip': rs[0]['chip'], 'waze': rs[0]['waze'],
            'src': rs[0]['src'], 'n': len(rs),
            'sec': round((rs[-1]['t'] - rs[0]['t']) / 1000.0, 1),
            'lat': rs[0]['lat'], 'lng': rs[0]['lng'],
            'at': rs[0]['t'] - t0,
        })
    eps.sort(key=lambda e: -e['sec'])

    html = _render(args.trip, rows, counts, eps, n, t0, args.vehicle,
                   nearby_segments(rows, segs))
    with open(args.out, 'w', encoding='utf-8') as fh:
        fh.write(html)
    print(f'{os.path.basename(args.trip)}: {n} fixes')
    for k in ('ok', 'class', 'bad', 'nowaze', 'none'):
        if counts.get(k):
            print(f'  {k:<7} {counts[k]:>5} ({100.0 * counts[k] / n:.1f}%)')
    print(f'  worst episodes: '
          f'{[(e["street"], e["sec"], e["chip"], e["waze"]) for e in eps[:5]]}')
    print(f'wrote {args.out}')
    return 0


def _svg_map(rows, seglines, eps, w=1000, h=580):
    """Offline map: plain SVG, no tiles, no network, no JS.

    The Leaflet view below needs CARTO tiles over the network, which the
    embedded browser frequently blocks — so the drawing that matters (the Waze
    segments and the driven track, value-coloured) is emitted as vectors here.
    Projection is local equirectangular with cos(lat) so the shape is not
    stretched.
    """
    lats = [r['lat'] for r in rows]
    lngs = [r['lng'] for r in rows]
    k = math.cos(math.radians((min(lats) + max(lats)) / 2))
    ux = [v * k for v in lngs]
    ux0, ux1 = min(ux), max(ux)
    uy0, uy1 = min(lats), max(lats)
    span_x = max(1e-6, ux1 - ux0)
    span_y = max(1e-6, uy1 - uy0)
    s = min((w * 0.92) / span_x, (h * 0.88) / span_y)
    off_x = (w - span_x * s) / 2
    off_y = (h - span_y * s) / 2

    def X(lng):
        return off_x + (lng * k - ux0) * s

    def Y(lat):
        return h - off_y - (lat - uy0) * s

    def vcol(v):
        return ('#d93025' if v >= 80 else '#f9ab00' if v >= 60
                else '#188038' if v >= 50 else '#8ab4f8' if v >= 40
                else '#5f6368')

    state_col = {'ok': '#188038', 'class': '#f9ab00', 'bad': '#d93025',
                 'nowaze': '#9b59b6', 'none': '#2f3436'}
    out = [f'<svg viewBox="0 0 {w} {h}" width="100%" height="{h}" '
           f'style="background:#101418;display:block">',
           f'<rect width="{w}" height="{h}" fill="#101418"/>']
    # Waze layer: dashed, value-coloured
    for seg in seglines:
        v = max(seg['fwd'] or 0, seg['rev'] or 0)
        pts = ' '.join(f'{X(p[1]):.1f},{Y(p[0]):.1f}' for p in seg['pts'])
        out.append(f'<polyline points="{pts}" fill="none" '
                   f'stroke="{vcol(v)}" stroke-width="2.5" opacity=".45" '
                   f'stroke-dasharray="5,4"><title>{seg["street"] or "(unnamed)"}'
                   f' — Waze fwd {seg["fwd"]} / rev {seg["rev"]}</title>'
                   f'</polyline>')
    # the driven track, coloured by whether the chip agreed with that layer
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        out.append(f'<line x1="{X(a["lng"]):.1f}" y1="{Y(a["lat"]):.1f}" '
                   f'x2="{X(b["lng"]):.1f}" y2="{Y(b["lat"]):.1f}" '
                   f'stroke="{state_col.get(b["state"], "#5f6368")}" '
                   f'stroke-width="4" opacity=".95"/>')
    # disagreement episodes: marker + label
    for e in eps[:12]:
        cx, cy = X(e['lng']), Y(e['lat'])
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="#d93025" '
                   f'stroke="#fff" stroke-width="1.5"/>'
                   f'<text x="{cx + 9:.1f}" y="{cy + 4:.1f}" fill="#f2f2f2" '
                   f'font-size="11" font-family="system-ui">{e["street"][:18]} '
                   f'{e["chip"]}→layer {e["waze"]} ({e["sec"]:.0f}s)</text>')
    out.append(f'<text x="12" y="{h - 12}" fill="#8a8a8a" font-size="11" '
               f'font-family="system-ui">dashed = the Waze segment layer '
               f'(green 50 · orange 60 · blue 40 · red 80+) · thick = your '
               f'track: green matched the layer · orange stayed on the class '
               f'default while a segment existed · red differed from it · '
               f'violet no segment at all · {len(seglines)} segments</text>')
    out.append('</svg>')
    return ''.join(out)


def _render(trip, rows, counts, eps, n, t0, vehicle, seglines) -> str:
    """Self-contained Leaflet page (tiles need network; the data does not)."""
    data = json.dumps(rows, separators=(',', ':'))
    eps_json = json.dumps(eps, separators=(',', ':'))
    segs_json = json.dumps(list(seglines.values()), separators=(',', ':'))
    title = os.path.basename(trip)
    gen = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>Limit audit — {title}</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
 body{{margin:0;font:13px/1.45 system-ui,sans-serif;background:#111;color:#eee}}
 #map{{height:44vh}}
 .bar{{display:flex;gap:14px;flex-wrap:wrap;padding:8px 12px;background:#1b1b1b;
      border-bottom:1px solid #333}}
 .k{{display:flex;align-items:center;gap:6px}}
 .sw{{width:12px;height:12px;border-radius:3px;display:inline-block}}
 table{{border-collapse:collapse;width:100%}}
 th,td{{padding:3px 8px;border-bottom:1px solid #2a2a2a;text-align:left;
      font-variant-numeric:tabular-nums}}
 th{{position:sticky;top:0;background:#191919}}
 tr.bad td{{background:#3a1414}} tr.class td{{background:#3a2c10}}
 #panel{{max-height:34vh;overflow:auto}}
 #chart{{width:100%;height:110px;display:block;background:#161616}}
</style></head><body>
<div class="bar">
  <b>{title}</b><span>{gen} · {vehicle} · {n} fixes</span>
  <span class="k"><i class="sw" style="background:#188038"></i>chip = the Waze
    layer {counts.get('ok', 0)}</span>
  <span class="k"><i class="sw" style="background:#f9ab00"></i>segment existed,
    chip stayed on the class default {counts.get('class', 0)}</span>
  <span class="k"><i class="sw" style="background:#d93025"></i>chip differed from
    the layer (sign / cache) {counts.get('bad', 0)}</span>
  <span class="k"><i class="sw" style="background:#9b59b6"></i>no Waze segment
    within 25 m → class default {counts.get('nowaze', 0)}</span>
  <span class="k"><i class="sw" style="background:#2f3436"></i>no limit shown
    at all {counts.get('none', 0)}</span>
  <span class="k">— dashed = the Waze layer under you:
    <i class="sw" style="background:#8ab4f8"></i>40
    <i class="sw" style="background:#188038"></i>50
    <i class="sw" style="background:#f9ab00"></i>60
    <i class="sw" style="background:#d93025"></i>80+</span>
  <span class="k">{len(seglines)} segment polylines drawn</span>
</div>
<svg id="chart"></svg>
{_svg_map(rows, list(seglines.values()), eps)}
<div id="map"></div>
<div id="panel"><table id="tbl">
<thead><tr><th>at (s)</th><th>state</th><th>street</th><th>class</th>
<th>road cls</th><th>waze</th><th>chip</th><th>source</th><th>seconds</th>
<th>fixes</th></tr></thead><tbody></tbody></table></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const ROWS={data}, EPS={eps_json}, SEGLINES={segs_json};
const COL={{ok:'#188038',class:'#f9ab00',bad:'#d93025',nowaze:'#9b59b6',
fnone:'#2f3436'}};
const col=s=>COL[s]||'#5f6368';
const vcol=v=>v>=80?'#d93025':v>=60?'#f9ab00':v>=50?'#188038':v>=40?'#8ab4f8'
  :'#5f6368';
const map=L.map('map');
L.tileLayer('https://{{s}}.basemaps.cartocdn.com/dark_all/{{z}}/{{x}}/{{y}}.png',
  {{maxZoom:19,attribution:'© OpenStreetMap © CARTO'}}).addTo(map);
// 1. the Waze layer itself: a dashed line per segment, coloured by its value
for(const s of SEGLINES){{
  const v=Math.max(s.fwd||0,s.rev||0);
  L.polyline(s.pts,{{color:vcol(v),weight:3,opacity:.7,dashArray:'4,3'
   ,interactive:true}}).addTo(map).bindPopup(
   `<b>${{s.street||'(unnamed segment)'}}</b><br>Waze fwd ${{s.fwd}} /
    rev ${{s.rev}} km/h`);}}
// 2. the driven track, coloured by whether the chip agreed with that layer
for(let i=1;i<ROWS.length;i++){{
  L.polyline([[ROWS[i-1].lat,ROWS[i-1].lng],[ROWS[i].lat,ROWS[i].lng]],
   {{color:col(ROWS[i].state),weight:6,opacity:.95}}).addTo(map);}}
map.fitBounds(ROWS.map(r=>[r.lat,r.lng]),{{padding:[20,20]}});
// disagreement markers (episode centres) with a tooltip
for(const e of EPS){{if(e.state!=='bad')continue;
  L.circleMarker([e.lat,e.lng],{{radius:7,color:'#fff',weight:2,
   fillColor:'#d93025',fillOpacity:1}}).addTo(map).bindPopup(
   `<b>${{e.street}}</b><br>class ${{e.hw}} → ${{e.cls}} km/h<br>
    waze <b>${{e.waze??'–'}}</b> · chip <b>${{e.chip}}</b> (${{e.src}})<br>
    ${{e.n}} fixes / ${{e.sec}} s`);}}
// episode table
const tb=document.querySelector('#tbl tbody');
for(const e of EPS){{const tr=document.createElement('tr');tr.className=e.state;
 tr.innerHTML=`<td>${{e.at/1000}}</td><td>${{e.state}}</td><td>${{e.street}}</td>
  <td>${{e.hw}}</td><td>${{e.cls}}</td><td>${{e.waze??'–'}}</td>
  <td><b>${{e.chip??'–'}}</b></td><td>${{e.src}}</td><td>${{e.sec}}</td>
  <td>${{e.n}}</td>`;
 tr.onclick=()=>map.setView([e.lat,e.lng],18);tb.appendChild(tr);}}
// strip chart: waze vs chip vs class over time
const svg=document.getElementById('chart'),W=svg.clientWidth||900,H=110;
svg.setAttribute('viewBox',`0 0 ${{W}} ${{H}}`);
const maxV=Math.max(...ROWS.map(r=>r.chip||0),...ROWS.map(r=>r.waze||0),60)+5;
const T0=ROWS[0].t,T1=ROWS[ROWS.length-1].t,span=Math.max(1,T1-T0);
const X=t=>20+(W-30)*(t-T0)/span, Y=v=>H-14-(H-30)*v/maxV;
const line=(pick,c)=>{{let d='';for(const r of ROWS){{const v=pick(r);
 if(!v){{continue;}}d+=`${{d?'L':'M'}}${{X(r.t).toFixed(1)}},${{Y(v).toFixed(1)}}`;}}
 return `<path d="${{d}}" fill="none" stroke="${{c}}" stroke-width="2"/>`;}};
svg.innerHTML=
 `<rect x="0" y="0" width="${{W}}" height="${{H}}" fill="#161616"/>`
 +line(r=>r.waze,'#8ab4f8')+line(r=>r.chip,'#f9ab00')
 +line(r=>r.cls,'#5f6368')
 +[0,30,50,60,80].map(v=>`<text x="2" y="${{Y(v)+4}}" fill="#888"
    font-size="10">${{v}}</text>`).join('')
 +`<text x="${{W-150}}" y="12" fill="#8ab4f8" font-size="11">waze</text>
   <text x="${{W-100}}" y="12" fill="#f9ab00" font-size="11">chip</text>
   <text x="${{W-50}}" y="12" fill="#5f6368" font-size="11">class</text>`;
</script></body></html>
"""


if __name__ == '__main__':
    sys.exit(main())
