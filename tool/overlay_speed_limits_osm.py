#!/usr/bin/env python3
"""Overlay vietnam_speed_limits.geojson (DATMAP) on an OSM basemap.

Pure-Python (no third-party deps). Reads the 93k-segment GeoJSON, simplifies
each line with Douglas-Peucker, and emits a self-contained HTML slippy map:

  docs/speed_limits_osm.html

The HTML is a dependency-free Web-Mercator tile viewer: it loads OSM raster
tiles (tile.openstreetmap.org) straight onto a <canvas> and draws every
speed-limit segment as a colored polyline on top, with pan/zoom + legend.

Color ramp (VN posted limits):
  30 #8d99ae (gray)  40 #2a9d8f (teal)  50 #457b9d (blue)  60 #e9c46a (yellow)
  70 #f4a261 (orange) 80 #e76f51 (red)  90 #c1121f (dark red)  100+ #6f1d1b
  0  #64748b (no data, faint)
"""
import collections
import json
import math
import os
import sys

SRC = os.path.join(
    os.path.dirname(__file__), '..', 'assets', 'offline_map',
    'vietnam_speed_limits.geojson',
)
OUT_DIR = os.path.join(os.path.dirname(__file__), '..', 'docs')
os.makedirs(OUT_DIR, exist_ok=True)

DP_TOL_DEG = 0.0004  # Douglas-Peucker tolerance (~44 m) — keeps the map light


def bucket_for(speed):
    """Bin a raw speed value to (label, color). Odd values in the data
    (5/10/15/20/29/35/39/42/70/125/130/140/150) snap to the nearest band."""
    if not speed or speed < 1:
        return ('no data', '#64748b')
    if speed < 30:
        return ('<=30 km/h', '#8d99ae')
    if speed < 40:
        return ('30 km/h', '#8d99ae')
    if speed < 50:
        return ('40 km/h', '#2a9d8f')
    if speed < 60:
        return ('50 km/h', '#457b9d')
    if speed < 70:
        return ('60 km/h', '#e9c46a')
    if speed < 80:
        return ('70 km/h', '#f4a261')
    if speed < 90:
        return ('80 km/h', '#e76f51')
    if speed < 100:
        return ('90 km/h', '#c1121f')
    return ('100+ km/h', '#6f1d1b')


def douglas_peucker(pts, tol):
    """Simplify a polyline [(lon,lat), ...] with the Douglas-Peucker algo."""
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        x1, y1 = pts[a]
        x2, y2 = pts[b]
        dx, dy = x2 - x1, y2 - y1
        denom = dx * dx + dy * dy or 1e-12
        max_d, idx = -1.0, -1
        for i in range(a + 1, b):
            x, y = pts[i]
            # perpendicular distance to segment a-b
            t = ((x - x1) * dx + (y - y1) * dy) / denom
            t = max(0.0, min(1.0, t))
            px, py = x1 + t * dx, y1 + t * dy
            d = math.hypot(x - px, y - py)
            if d > max_d:
                max_d, idx = d, i
        if max_d > tol:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for p, k in zip(pts, keep) if k]


def mercator(lon, lat):
    """Web-Mercator unit coords (0..1) for (lon, lat)."""
    x = (lon + 180.0) / 360.0
    lat = max(-85.0511, min(85.0511, lat))
    r = math.radians(lat)
    y = (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0
    return round(x, 7), round(y, 7)


def simplify_geom(g):
    """Return a list of simplified point lists for one feature geometry."""
    coords = g['coordinates']
    parts = coords if g['type'] == 'MultiLineString' else [coords]
    out = []
    for part in parts:
        if len(part) < 2:
            continue
        simp = douglas_peucker([tuple(c[:2]) for c in part], DP_TOL_DEG)
        if len(simp) >= 2:
            out.append(simp)
    return out


def main():
    print('loading %s ...' % SRC)
    with open(SRC) as f:
        data = json.load(f)
    feats = data['features']
    print('features:', len(feats))

    buckets = collections.defaultdict(list)  # bucket key -> list of (bbox, flat_pts)
    counts = collections.Counter()
    kept_lines = 0

    for ft in feats:
        pr = ft['properties']
        g = ft['geometry']
        sp = max(pr.get('fwdMaxSpeed') or 0, pr.get('revMaxSpeed') or 0)
        label, color = bucket_for(sp)
        key = label  # group by label so equal bands share a color
        for simp in simplify_geom(g):
            flat = []
            bux0 = buy0 = float('inf')
            bux1 = buy1 = float('-inf')
            for lon, lat in simp:
                ux, uy = mercator(lon, lat)
                flat.extend((ux, uy))
                bux0 = min(bux0, ux); bux1 = max(bux1, ux)
                buy0 = min(buy0, uy); buy1 = max(buy1, uy)
            buckets[key].append((bux0, buy0, bux1, buy1, flat))
            counts[key] += 1
            kept_lines += 1

    print('lines kept:', kept_lines)
    print('per-bucket line counts:', dict(sorted(counts.items(), key=lambda kv: kv[0])))

    def color_from_label(label):
        if label == 'no data':
            return '#64748b'
        if label.startswith('<='):
            return '#8d99ae'
        return bucket_for(int(label.split()[0].rstrip('+')))[1]

    COLOR_BY_LABEL = {label: color_from_label(label) for label in counts}

    # Build compact JS data object
    js_buckets = []
    legend_rows = []
    for label in sorted(counts, key=lambda s: (s == 'no data', s)):
        lines = buckets[label]
        color = COLOR_BY_LABEL[label]
        js_lines = '[%s]' % ','.join(
            '[%.6f,%.6f,%.6f,%.6f,%s]' % (b[0], b[1], b[2], b[3],
                                          ','.join('%.6f' % v for v in b[4]))
            for b in lines
        )
        js_buckets.append('{c:"%s",n:%d,l:%s}' % (color, counts[label], js_lines))
        legend_rows.append(
            '<div><span class="sw" style="background:%s"></span>%s — %d</div>'
            % (color, label, counts[label])
        )

    html = """<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8"/>
<title>VN speed limits over OSM (DATMAP)</title>
<style>
  html,body{margin:0;height:100%;overflow:hidden;font-family:system-ui,sans-serif;color:#e2e8f0}
  #map{position:fixed;inset:0;background:#aad3df}
  #cv{position:absolute;inset:0}
  #bar{position:fixed;left:10px;top:10px;background:#1e293bdd;border:1px solid #475569;
       border-radius:8px;padding:6px 10px;font-size:13px;z-index:9;max-width:46vw}
  #bar b{color:#fbbf24}
  #legend{position:fixed;right:10px;top:10px;background:#1e293bdd;border:1px solid #475569;
       border-radius:8px;padding:8px 10px;font-size:12px;z-index:9;line-height:1.7}
  #legend .sw{display:inline-block;width:14px;height:14px;margin-right:6px;
       vertical-align:-2px;border-radius:3px}
  #attr{position:fixed;right:10px;bottom:6px;font-size:10px;color:#334155;
       background:#ffffffcc;padding:2px 6px;border-radius:4px;z-index:9}
</style>
</head>
<body>
<div id="bar">Việt Nam · posted speed limits (DATMAP) · <b>__N__</b> segments
  over OpenStreetMap — drag to pan · scroll to zoom</div>
<div id="legend">__LEGEND__</div>
<div id="map"><canvas id="cv"></canvas></div>
<div id="attr">© OpenStreetMap contributors</div>
<script>
const BUCKETS=[__BUCKETS__];
const TILE=256, MAXZ=18, MINZ=5;
const cv=document.getElementById('cv'), ctx=cv.getContext('2d',{willReadFrequently:true});
let W=0,H=0,Z=6,cx=0.5,cy=0.5;         // center in web-mercator unit coords
let scale=1;                            // device-pixel ratio
const tiles={}; let dirty=false; let raf=false;

function requestRender(){ dirty=true; if(raf)return; raf=true;
  requestAnimationFrame(()=>{raf=false; if(dirty){dirty=false; render();}}); }

// ---- auto-fit to data bbox (initial view) ----
(function(){
  let ux0=1,uy0=1,ux1=0,uy1=0;
  for(const b of BUCKETS) for(const l of b.l){
    ux0=Math.min(ux0,l[0]);uy0=Math.min(uy0,l[1]);
    ux1=Math.max(ux1,l[2]);uy1=Math.max(uy1,l[3]);}
  const m=1.15;
  cx=(ux0+ux1)/2; cy=(uy0+uy1)/2;
  function fit(){
    const zx=Math.log2(W/((ux1-ux0)*TILE*m));
    const zy=Math.log2(H/((uy1-uy0)*TILE*m));
    Z=Math.max(MINZ,Math.min(MAXZ,Math.floor(Math.min(zx,zy))));
  }
  window.addEventListener('load',()=>{resize();fit();requestRender();});
})();

function resize(){scale=window.devicePixelRatio||1;
  W=window.innerWidth; H=window.innerHeight;
  cv.width=W*scale; cv.height=H*scale;
  cv.style.width=W+'px'; cv.style.height=H+'px'; ctx.setTransform(scale,0,0,scale,0,0);}

// ---- tile loading (OSM; retries transient failures) ----
function tileKey(z,x,y){return z+'/'+x+'/'+y;}
function loadTile(z,x,y){
  const k=tileKey(z,x,y);
  if(tiles[k]!==undefined||z<0||y<0||x>=Math.pow(2,z))return;
  const im=new Image();
  im.onload=()=>{tiles[k]={im,z,x,y}; requestRender();};
  im.onerror=()=>{ delete tiles[k];
    setTimeout(()=>loadTile(z,x,y), 2500); };   // retry after a quiet gap
  tiles[k]=null; im.src='https://tile.openstreetmap.org/'+k+'.png';
}

// ---- render ----
function render(){
  const S=256*Math.pow(2,Z);
  const offX=cx*S-W/2, offY=cy*S-H/2;
  const x0=Math.floor(offX/TILE), y0=Math.floor(offY/TILE);
  const x1=Math.floor((offX+W)/TILE), y1=Math.floor((offY+H)/TILE);
  ctx.fillStyle='#aad3df'; ctx.fillRect(0,0,W,H);
  for(let ty=y0;ty<=y1;ty++)for(let tx=x0;tx<=x1;tx++){
    const t=tiles[tileKey(Z,tx,ty)];
    if(t) ctx.drawImage(t.im,t.x*TILE-offX,t.y*TILE-offY,TILE,TILE);
  }
  // viewport in unit coords for culling
  const vx0=offX/S, vy0=offY/S, vx1=(offX+W)/S, vy1=(offY+H)/S;
  for(const b of BUCKETS){
    ctx.strokeStyle=b.c; ctx.lineWidth=2.2; ctx.lineCap='round'; ctx.lineJoin='round';
    ctx.beginPath();
    for(const l of b.l){
      if(l[2]<vx0||l[0]>vx1||l[3]<vy0||l[1]>vy1) continue;
      for(let i=4;i<l.length;i+=2){
        const sx=l[i]*S-offX, sy=l[i+1]*S-offY;
        if(i===4) ctx.moveTo(sx,sy); else ctx.lineTo(sx,sy);
      }
    }
    ctx.stroke();
  }
  // prefetch tiles
  for(let ty=y0;ty<=y1;ty++)for(let tx=x0;tx<=x1;tx++)loadTile(Z,tx,ty);
}

// ---- interactions ----
let drag=null;
cv.addEventListener('mousedown',e=>{drag={x:e.clientX,y:e.clientY,cx,cy};
  cv.style.cursor='grabbing';e.preventDefault();});
window.addEventListener('mousemove',e=>{if(!drag)return;
  cx=drag.cx-(e.clientX-drag.x)/(256*Math.pow(2,Z));
  cy=drag.cy-(e.clientY-drag.y)/(256*Math.pow(2,Z));
  requestRender();});
window.addEventListener('mouseup',()=>{drag=null;cv.style.cursor='grab';});
cv.addEventListener('wheel',e=>{e.preventDefault();
  const nz=Math.max(MINZ,Math.min(MAXZ,Z+(e.deltaY<0?1:-1)));
  if(nz===Z)return;
  const rect=cv.getBoundingClientRect();
  const px=e.clientX-rect.left, py=e.clientY-rect.top;
  const S0=256*Math.pow(2,Z), S1=256*Math.pow(2,nz);
  cx=(cx*S0-px)/S0 + px/S1; cy=(cy*S0-py)/S0 + py/S1;
  Z=nz; requestRender();},{passive:false});
window.addEventListener('resize',()=>{resize();requestRender();});
cv.style.cursor='grab';
</script>
</body>
</html>
"""
    html = (html
            .replace('__N__', str(kept_lines))
            .replace('__LEGEND__', '\n'.join(legend_rows))
            .replace('__BUCKETS__', ','.join(js_buckets)))
    out = os.path.join(OUT_DIR, 'speed_limits_osm.html')
    with open(out, 'w') as f:
        f.write(html)
    size_mb = os.path.getsize(out) / 1e6
    print('wrote', out, '(%.1f MB)' % size_mb)
    return 0


if __name__ == '__main__':
    sys.exit(main())
