#!/usr/bin/env python3
"""Overlay the Waze point-notice coverage (speed cameras + posted limits) on OSM.

Pure-Python (no third-party deps). Reads:
  - assets/offline_map/waze_speed_limits.json  (4,694 points with kmh)
  - assets/offline_map/vietnam_cameras.json    (source == 'waze' cameras)
and emits a self-contained HTML slippy map:

  docs/waze_coverage.html

The HTML is a dependency-free Web-Mercator tile viewer (same engine as
overlay_speed_limits_osm.py): loads OSM raster tiles onto a <canvas>, draws the
Waze speed-limit points colored by posted speed, with pan/zoom + legend +
counts + a density-heat toggle so you can SEE where the Waze data covers.

Color ramp (matches the DATMAP viewer):
  30 #8d99ae  40 #2a9d8f  50 #457b9d  60 #e9c46a  70 #f4a261
  80 #e76f51  90 #c1121f  100+ #6f1d1b
"""
import collections
import json
import math
import os

ROOT = os.path.join(os.path.dirname(__file__), '..')
SPD = os.path.join(ROOT, 'assets', 'offline_map', 'waze_speed_limits.json')
CAM = os.path.join(ROOT, 'assets', 'offline_map', 'vietnam_cameras.json')
OUT_DIR = os.path.join(ROOT, 'docs')
os.makedirs(OUT_DIR, exist_ok=True)
OUT = os.path.join(OUT_DIR, 'waze_coverage.html')


def bucket_for(speed):
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


def mercator(lon, lat):
    x = (lon + 180.0) / 360.0
    lat = max(-85.0511, min(85.0511, lat))
    r = math.radians(lat)
    y = (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0
    return round(x, 7), round(y, 7)


def region_bin(lat, lng):
    if lat >= 22.5:
        return 'Tây Bắc / biên giới'
    if lat >= 21.5:
        return 'Đồng bằng sông Hồng (HN)'
    if 18 <= lat < 21.5:
        return 'Bắc Trung Bộ'
    if 15.5 <= lat < 18:
        return 'Miền Trung (ĐN/ Huế)'
    if 12.5 <= lat < 15.5:
        return 'Nam Trung Bộ (Nha Trang…)'
    return 'Nam Bộ (TPHCM/ ĐBSCL)'


def main():
    with open(SPD) as f:
        spd = json.load(f)
    pts = spd['points']
    print('waze speed points:', len(pts))

    buckets = collections.defaultdict(list)
    counts = collections.Counter()
    regions = collections.Counter()
    ux0 = uy0 = float('inf')
    ux1 = uy1 = float('-inf')
    for p in pts:
        kmh = p['kmh']
        label, color = bucket_for(kmh)
        ux, uy = mercator(p['lng'], p['lat'])
        buckets[label].append((ux, uy, kmh))
        counts[label] += 1
        regions[region_bin(p['lat'], p['lng'])] += 1
        ux0 = min(ux0, ux); uy0 = min(uy0, uy)
        ux1 = max(ux1, ux); uy1 = max(uy1, uy)

    # Waze cameras (all, incl. any without parseable speed)
    cams = []
    try:
        cd = json.load(open(CAM))
        cams = [c for c in cd.get('cameras', []) if c.get('source') == 'waze']
    except Exception:
        pass
    print('waze cameras:', len(cams))
    cam_js = [mercator(c['lng'], c['lat']) for c in cams]
    cam_js = ['[%.6f,%.6f]' % (x, y) for x, y in cam_js]

    def color_from_label(label):
        if label.startswith('<='):
            return '#8d99ae'
        return bucket_for(int(label.split()[0].rstrip('+')))[1]

    COLOR_BY_LABEL = {label: color_from_label(label) for label in counts}

    js_buckets = []
    legend_rows = []
    for label in sorted(counts, key=lambda s: (s == 'no data', s)):
        color = COLOR_BY_LABEL[label]
        ptsjs = ','.join('[%.6f,%.6f,%d]' % (x, y, kmh)
                         for (x, y, kmh) in buckets[label])
        js_buckets.append('{c:"%s",n:%d,p:[%s]}' % (color, counts[label], ptsjs))
        legend_rows.append(
            '<div><span class="sw" style="background:%s"></span>%s — <b>%d</b></div>'
            % (color, label, counts[label]))

    region_rows = ''.join(
        '<div class="rv"><span class="rd"></span>%s: <b>%d</b></div>' % (k, v)
        for k, v in regions.most_common())

    html = """<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8"/>
<title>Waze mod data coverage over OSM</title>
<style>
  html,body{margin:0;height:100%;overflow:hidden;font-family:system-ui,sans-serif;color:#e2e8f0}
  #map{position:fixed;inset:0;background:#aad3df}
  #cv{position:absolute;inset:0}
  #bar{position:fixed;left:10px;top:10px;background:#1e293bdd;border:1px solid #475569;
       border-radius:8px;padding:6px 10px;font-size:13px;z-index:9;max-width:52vw}
  #bar b{color:#fbbf24}
  #panel{position:fixed;right:10px;top:10px;width:224px;background:#1e293bdd;border:1px solid #475569;
       border-radius:8px;padding:8px 10px;font-size:12px;z-index:9;line-height:1.7}
  #panel h3{margin:2px 0 6px;font-size:12px;color:#93c5fd}
  #panel .sw{display:inline-block;width:13px;height:13px;margin-right:6px;vertical-align:-2px;border-radius:3px}
  #panel .rv{font-size:11px;color:#cbd5e1}
  #panel .rd{display:inline-block;width:9px;height:9px;border-radius:2px;background:#7dd3fc;margin-right:6px}
  .tgl{display:flex;align-items:center;gap:6px;margin:6px 0 2px;font-size:12px;cursor:pointer}
  .tgl input{accent-color:#fbbf24}
  #attr{position:fixed;right:10px;bottom:6px;font-size:10px;color:#334155;background:#ffffffcc;
       padding:2px 6px;border-radius:4px;z-index:9}
</style>
</head>
<body>
<div id="bar">Waze mod · point-notice coverage — <b>__N__</b> posted speed points
  over OpenStreetMap — drag to pan · scroll to zoom</div>
<div id="panel">
  <h3>Tốc độ (giới hạn từ Waze)</h3>
  __LEGEND__
  <div class="tgl"><input type="checkbox" id="tHeat" checked><label for="tHeat">Mật độ (heat)</label></div>
  <div class="tgl"><input type="checkbox" id="tCam"><label for="tCam">Cameras Waze (__CAMN__)</label></div>
  <div class="tgl"><input type="checkbox" id="tGrid"><label for="tGrid">Lưới 1°</label></div>
  <h3 style="margin-top:10px">Phân bố theo vùng</h3>
  __REGIONS__
</div>
<div id="map"><canvas id="cv"></canvas></div>
<div id="attr">© OpenStreetMap contributors</div>
<script>
const BUCKETS=[__BUCKETS__];
const CAMS=[__CAMS__];
const TILE=256, MAXZ=18, MINZ=5;
const cv=document.getElementById('cv'), ctx=cv.getContext('2d',{willReadFrequently:true});
let W=0,H=0,Z=6,cx=0.5,cy=0.5,scale=1;
const tiles={}; let dirty=false; let raf=false;
let showHeat=true, showCam=false, showGrid=false;
const HEAT={};

function requestRender(){ dirty=true; if(raf)return; raf=true;
  requestAnimationFrame(()=>{raf=false; if(dirty){dirty=false; render();}}); }

// ---- precompute heat grid (0.05° cells, world units) ----
(function(){
  const cell=0.05/360.0;
  for(const b of BUCKETS) for(const p of b.p){
    const kx=Math.floor(p[0]/cell), ky=Math.floor(p[1]/cell);
    const k=kx+','+ky; HEAT[k]=HEAT[k]?HEAT[k]+1:1;
  }
  // normalize to 0..1
  let mx=0; for(const k in HEAT) mx=Math.max(mx,HEAT[k]);
  for(const k in HEAT) HEAT[k]=HEAT[k]/mx;
})();

// ---- auto-fit to data bbox ----
(function(){
  let ux0=1,uy0=1,ux1=0,uy1=0;
  for(const b of BUCKETS) for(const p of b.p){
    ux0=Math.min(ux0,p[0]);uy0=Math.min(uy0,p[1]);
    ux1=Math.max(ux1,p[0]);uy1=Math.max(uy1,p[1]);}
  const m=1.12; cx=(ux0+ux1)/2; cy=(uy0+uy1)/2;
  function fit(){
    const zx=Math.log2(W/((ux1-ux0)*TILE*m));
    const zy=Math.log2(H/((uy1-uy0)*TILE*m));
    Z=Math.max(MINZ,Math.min(MAXZ,Math.floor(Math.min(zx,zy))));}
  window.addEventListener('load',()=>{resize();fit();requestRender();});
})();

function resize(){scale=window.devicePixelRatio||1;
  W=window.innerWidth; H=window.innerHeight;
  cv.width=W*scale; cv.height=H*scale;
  cv.style.width=W+'px'; cv.style.height=H+'px';
  ctx.setTransform(scale,0,0,scale,0,0);}

function tileKey(z,x,y){return z+'/'+x+'/'+y;}
function loadTile(z,x,y){
  const k=tileKey(z,x,y);
  if(tiles[k]!==undefined||z<0||y<0||x>=Math.pow(2,z))return;
  const im=new Image();
  im.onload=()=>{tiles[k]={im,z,x,y}; requestRender();};
  im.onerror=()=>{ delete tiles[k]; setTimeout(()=>loadTile(z,x,y),2500); };
  tiles[k]=null; im.src='https://tile.openstreetmap.org/'+k+'.png';
}

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
  const vx0=offX/S, vy0=offY/S, vx1=(offX+W)/S, vy1=(offY+H)/S;

  // density heat
  if(showHeat){
    const cell=0.05/360.0, cs=cell*S;
    const hx0=Math.floor(vx0/cell), hx1=Math.floor(vx1/cell);
    const hy0=Math.floor(vy0/cell), hy1=Math.floor(vy1/cell);
    for(let ky=hy0;ky<=hy1;ky++)for(let kx=hx0;kx<=hx1;kx++){
      const v=HEAT[kx+','+ky]; if(!v) continue;
      const x=(kx*cell)*S-offX, y=(ky*cell)*S-offY;
      ctx.fillStyle='rgba(251,191,36,'+(0.06+0.30*v).toFixed(2)+')';
      ctx.fillRect(x,y,Math.max(1,cs+0.5),Math.max(1,cs+0.5));
    }
  }

  // 1° grid
  if(showGrid){
    ctx.strokeStyle='rgba(255,255,255,0.25)'; ctx.lineWidth=1;
    const deg=1.0/360.0, ds=deg*S;
    for(let gx=Math.floor(vx0/deg);gx<=Math.floor(vx1/deg);gx++){
      const x=gx*deg*S-offX; ctx.beginPath(); ctx.moveTo(x,0); ctx.lineTo(x,H); ctx.stroke();}
    for(let gy=Math.floor(vy0/deg);gy<=Math.floor(vy1/deg);gy++){
      const y=gy*deg*S-offY; ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(W,y); ctx.stroke();}
  }

  // waze cameras (all)
  if(showCam){
    ctx.fillStyle='rgba(148,163,184,0.55)';
    for(const c of CAMS){
      const x=c[0]*S-offX, y=c[1]*S-offY;
      if(x<-8||x>W+8||y<-8||y>H+8) continue;
      ctx.beginPath(); ctx.arc(x,y,3,0,6.2832); ctx.fill();}
  }

  // speed points
  const r=Math.max(2,Math.min(6,2.2*Math.pow(2,Z-6)));
  for(const b of BUCKETS){
    ctx.fillStyle=b.c; ctx.beginPath();
    for(const p of b.p){
      const x=p[0]*S-offX, y=p[1]*S-offY;
      if(x<-r||x>W+r||y<-r||y>H+r) continue;
      ctx.moveTo(x+r,y); ctx.arc(x,y,r,0,6.2832);
    }
    ctx.fill();
  }
}

// ---- interactions ----
let drag=false, lx=0, ly=0;
cv.addEventListener('mousedown',e=>{drag=true;lx=e.clientX;ly=e.clientY;});
window.addEventListener('mouseup',()=>drag=false);
window.addEventListener('mousemove',e=>{if(!drag)return;
  const S=256*Math.pow(2,Z);
  cx-=(e.clientX-lx)/S; cy-=(e.clientY-ly)/S; lx=e.clientX; ly=e.clientY;
  requestRender();});
cv.addEventListener('wheel',e=>{e.preventDefault();
  const f=e.deltaY<0?1.25:0.8;
  const nz=Math.max(MINZ,Math.min(MAXZ,Math.round(Z*Math.log(f)/Math.log(2)+Z)));
  if(nz===Z)return;
  const S=256*Math.pow(2,Z);
  const mx=e.clientX, my=e.clientY;
  const wx=(mx-(W/2))/S+cx, wy=(my-(H/2))/S+cy;
  Z=nz; cx=wx; cy=wy;
  requestRender();
}, {passive:false});
cv.addEventListener('touchstart',e=>{if(e.touches.length===1){drag=true;const t=e.touches[0];lx=t.clientX;ly=t.clientY;}},{passive:true});
cv.addEventListener('touchmove',e=>{if(drag&&e.touches.length===1){const t=e.touches[0];
  const S=256*Math.pow(2,Z); cx-=(t.clientX-lx)/S; cy-=(t.clientY-ly)/S; lx=t.clientX; ly=t.clientY; requestRender();}},{passive:true});
cv.addEventListener('touchend',()=>drag=false);

document.getElementById('tHeat').onchange=e=>{showHeat=e.target.checked;requestRender();};
document.getElementById('tCam').onchange=e=>{showCam=e.target.checked;requestRender();};
document.getElementById('tGrid').onchange=e=>{showGrid=e.target.checked;requestRender();};

window.addEventListener('resize',()=>{resize();requestRender();});
window.addEventListener('load',()=>{for(let z=0;z<=MAXZ;z++)
  loadTile(z,0,0); // warm
  // load tiles for current viewport after first render
  const iv=setInterval(()=>{const S=256*Math.pow(2,Z);
    const x0=Math.floor((cx*S-W/2)/TILE), y0=Math.floor((cy*S-H/2)/TILE);
    const x1=Math.floor((cx*S+W/2)/TILE), y1=Math.floor((cy*S+H/2)/TILE);
    for(let y=y0;y<=y1;y++)for(let x=x0;x<=x1;x++)loadTile(Z,x,y);}, 400);
  setTimeout(()=>clearInterval(iv), 20000);
});
</script>
</body>
</html>
"""
    html = (html.replace('__BUCKETS__', ','.join(js_buckets))
                .replace('__CAMS__', ','.join(cam_js))
                .replace('__LEGEND__', ''.join(legend_rows))
                .replace('__REGIONS__', region_rows)
                .replace('__N__', str(len(pts)))
                .replace('__CAMN__', str(len(cams))))
    with open(OUT, 'w') as f:
        f.write(html)
    print('wrote', OUT, 'size KB:', os.path.getsize(OUT) // 1024)
    print('per-band:', dict(counts))
    print('regions:', dict(regions.most_common()))


if __name__ == '__main__':
    main()
