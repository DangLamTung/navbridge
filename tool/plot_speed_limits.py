#!/usr/bin/env python3
"""Visualize vietnam_speed_limits.geojson (DATMAP speed-limit segments).

Pure-Python (no third-party deps): reads the 93k-segment GeoJSON and emits:
  - docs/speed_limits_stats.txt        : speed distribution + bounds
  - docs/speed_limits_map.svg          : static map, segments colored by limit
  - docs/speed_limits_map.html         : interactive pan/zoom + hover + legend

Color ramp (VN posted limits):
  30  #8d99ae (gray)   40  #2a9d8f (teal/green)
  50  #457b9d (blue)   60  #e9c46a (yellow)
  70  #f4a261 (orange) 80  #e76f51 (red)
  90  #c1121f (dark red)  100+ #6f1d1b (maroon)
"""
import collections
import json
import math
import os
import sys

SRC = os.path.join(
    os.path.dirname(__file__),
    '..', 'assets', 'offline_map', 'vietnam_speed_limits.geojson',
)
OUT_DIR = os.path.join(os.path.dirname(__file__), '..', 'docs')
os.makedirs(OUT_DIR, exist_ok=True)

W, H = 1000, 1400  # SVG canvas (portrait — Vietnam is tall)
PAD = 30


def color_for(speed):
    return {
        30: '#8d99ae',
        40: '#2a9d8f',
        50: '#457b9d',
        60: '#e9c46a',
        70: '#f4a261',
        80: '#e76f51',
        90: '#c1121f',
    }.get(speed, '#6f1d1b')  # 100+ → maroon


def main():
    print('loading %s ...' % SRC)
    with open(SRC) as f:
        data = json.load(f)
    feats = data['features']
    print('features:', len(feats))

    # --- pass 1: bounds + stats -------------------------------------------
    fwd = collections.Counter()
    rev = collections.Counter()
    both = collections.Counter()
    min_lon = min_lat = float('inf')
    max_lon = max_lat = float('-inf')
    npts = 0
    geoms = []  # keep geometry type + coords for pass 2

    for ft in feats:
        pr = ft['properties']
        g = ft['geometry']
        fw = pr.get('fwdMaxSpeed')
        rv = pr.get('revMaxSpeed')
        fwd[fw] += 1
        rev[rv] += 1
        both[max(fw or 0, rv or 0)] += 1
        coords = g['coordinates']
        npts += sum(len(c) for c in coords) if g['type'] == 'MultiLineString' else len(coords)
        for c in coords:
            if c and isinstance(c[0], (list, tuple)):
                for cc in c:
                    min_lon = min(min_lon, cc[0]); max_lon = max(max_lon, cc[0])
                    min_lat = min(min_lat, cc[1]); max_lat = max(max_lat, cc[1])
            elif c:
                min_lon = min(min_lon, c[0]); max_lon = max(max_lon, c[0])
                min_lat = min(min_lat, c[1]); max_lat = max(max_lat, c[1])
        geoms.append(g)

    def srt(c):
        return dict(sorted(c.items(), key=lambda kv: (kv[0] is None, kv[0])))

    with open(os.path.join(OUT_DIR, 'speed_limits_stats.txt'), 'w') as f:
        f.write('features: %d\n' % len(feats))
        f.write('total points: %d\n' % npts)
        f.write('lon range: %.4f .. %.4f\n' % (min_lon, max_lon))
        f.write('lat range: %.4f .. %.4f\n' % (min_lat, max_lat))
        f.write('fwdMaxSpeed distribution: %s\n' % srt(fwd))
        f.write('revMaxSpeed distribution: %s\n' % srt(rev))
        f.write('max(fwd,rev) distribution: %s\n' % srt(both))
    print('bounds lon %.4f..%.4f lat %.4f..%.4f' % (min_lon, max_lon, min_lat, max_lat))
    print('max(fwd,rev) dist:', dict(sorted(both.items())))

    # --- projection: equirectangular with cos(lat) aspect fix -------------
    mean_lat = math.radians((min_lat + max_lat) / 2.0)
    k = math.cos(mean_lat)
    sx = (W - 2 * PAD) / ((max_lon - min_lon) * k)
    sy = (H - 2 * PAD) / (max_lat - min_lat)
    s = min(sx, sy)

    def proj(lon, lat):
        x = PAD + (lon - min_lon) * k * s
        y = H - PAD - (lat - min_lat) * s  # flip y
        return x, y

    # --- pass 2: bucket path-strings by speed ------------------------------
    def render_geom(g, proj):
        coords = g['coordinates']
        parts = coords if g['type'] == 'MultiLineString' else [coords]
        out = []
        for part in parts:
            if len(part) < 2:
                continue
            pts = [proj(c[0], c[1]) for c in part]
            d = 'M %.1f %.1f L %s' % (pts[0][0], pts[0][1],
                                      ' '.join('%.1f %.1f' % p for p in pts[1:]))
            out.append(d)
        return out

    by_color = collections.defaultdict(list)
    for ft in feats:
        pr = ft['properties']
        g = ft['geometry']
        sp = max(pr.get('fwdMaxSpeed') or 0, pr.get('revMaxSpeed') or 0)
        for d in render_geom(g, proj):
            by_color[sp].append(d)

    svg = []
    svg.append(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d">' % (W, H, W, H)
    )
    svg.append('<rect width="%d" height="%d" fill="#0f172a"/>' % (W, H))
    svg.append(
        '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" '
        'font-size="18" font-weight="bold">Việt Nam — posted speed limits '
        '(DATMAP %d segments)</text>' % (PAD, PAD - 8, len(feats))
    )
    # base map silhouette: draw all segments in dark gray first
    svg.append(
        '<g stroke="#334155" stroke-width="0.6" fill="none">%s</g>' %
        ' '.join(
            '<path d="%s"/>' % d for lst in by_color.values() for d in lst
        )
    )
    # colored overlay per speed bucket
    for sp in sorted(by_color):
        col = color_for(sp)
        svg.append(
            '<g stroke="%s" stroke-width="1.1" fill="none" '
            'stroke-linecap="round">%s</g>' %
            (col, ' '.join('<path d="%s"/>' % d for d in by_color[sp]))
        )
    # legend
    ly = H - PAD + 14
    lx = PAD
    svg.append(
        '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" '
        'font-size="13" font-weight="bold">Speed limit (km/h):</text>' % (lx, ly)
    )
    lx += 160
    for sp in sorted(by_color):
        n = both[sp]
        svg.append('<rect x="%d" y="%d" width="14" height="14" fill="%s"/>'
                   % (lx, ly - 11, color_for(sp)))
        svg.append(
            '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" '
            'font-size="12">%d (%d)</text>' % (lx + 18, ly, sp, n)
        )
        lx += 92
    svg.append('</svg>')

    svg_path = os.path.join(OUT_DIR, 'speed_limits_map.svg')
    with open(svg_path, 'w') as f:
        f.write('\n'.join(svg))
    print('wrote', svg_path)

    # --- interactive HTML (pure JS pan/zoom, no CDN) ------------------------
    # Reuse the SVG markup, embedded, with a wrapper <g id="world"> + pan/zoom.
    inner = '\n'.join(svg[4:-1])  # drop <svg> open + </svg>
    html = """<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8"/>
<title>Vietnam speed limits (DATMAP)</title>
<style>
  html,body{margin:0;height:100%;background:#0f172a;font-family:system-ui,sans-serif;color:#e2e8f0}
  #wrap{position:fixed;inset:0;overflow:hidden;cursor:grab}
  #wrap.drag{cursor:grabbing}
  svg{display:block}
  #tip{position:fixed;pointer-events:none;background:#1e293b;border:1px solid #475569;
       border-radius:6px;padding:4px 8px;font-size:12px;display:none;z-index:9}
  #bar{position:fixed;top:8px;left:8px;background:#1e293bcc;border:1px solid #475569;
       border-radius:8px;padding:6px 10px;font-size:13px;z-index:9}
  #bar b{color:#fbbf24}
</style>
</head>
<body>
<div id="bar">Việt Nam · posted speed limits · <b>%(n)d</b> segments —
  drag to pan · scroll to zoom</div>
<div id="tip"></div>
<div id="wrap">%(svg)s</div>
<script>
  const wrap=document.getElementById('wrap');
  const svg=document.querySelector('#wrap svg');
  const tip=document.getElementById('tip');
  let vw=0,vh=0,scale=1,tx=0,ty=0;
  const W=%(W)d,H=%(H)d;
  function layout(){vw=window.innerWidth;vh=window.innerHeight;
    scale=Math.min(vw/W,vh/H)*1.0; svg.setAttribute('width',vw); svg.setAttribute('height',vh);
    apply();}
  function apply(){svg.style.transform=`translate(${tx}px,${ty}px) scale(${scale})`;
    svg.style.transformOrigin='0 0';}
  function clientToSvg(e){const r=svg.getBoundingClientRect();
    return [(e.clientX-r.left)/scale,(e.clientY-r.top)/scale];}
  let dragging=null;
  wrap.addEventListener('mousedown',e=>{dragging={x:e.clientX,y:e.clientY,tx,ty};
    wrap.classList.add('drag');e.preventDefault();});
  window.addEventListener('mousemove',e=>{if(dragging){
      tx=dragging.tx+e.clientX-dragging.x;ty=dragging.ty+e.clientY-dragging.y;apply();}
    else if(e.target.closest('path')){const p=e.target.closest('path');
      const s=p.getAttribute('data-speed'); if(s){tip.style.display='block';
        tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY+12)+'px';
        tip.textContent='Speed limit: '+s+' km/h';}}
    else tip.style.display='none';});
  window.addEventListener('mouseup',()=>{dragging=null;wrap.classList.remove('drag');});
  wrap.addEventListener('wheel',e=>{e.preventDefault();
    const f=e.deltaY<0?1.15:1/1.15; const ns=Math.max(0.2,Math.min(60,scale*f));
    const [mx,my]=clientToSvg(e);
    tx=e.clientX-mx*ns; ty=e.clientY-my*ns; scale=ns; apply();},{passive:false});
  window.addEventListener('resize',layout); layout();
</script>
</body>
</html>
"""
    # inject data-speed onto the colored paths
    # simpler: rebuild colored <path> with data-speed attr in a second pass
    colored = []
    for sp in sorted(by_color):
        col = color_for(sp)
        colored.append(
            '<g stroke="%s" stroke-width="1.1" fill="none" stroke-linecap="round">%s</g>'
            % (col, ' '.join('<path data-speed="%d" d="%s"/>' % (sp, d) for d in by_color[sp]))
        )
    svg2 = []
    svg2.append('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d">' % (W, H))
    svg2.append('<rect width="%d" height="%d" fill="#0f172a"/>' % (W, H))
    svg2.append(
        '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" font-size="18" '
        'font-weight="bold">Việt Nam — posted speed limits (DATMAP)</text>'
        % (PAD, PAD - 8)
    )
    svg2.append(
        '<g stroke="#334155" stroke-width="0.6" fill="none">%s</g>' %
        ' '.join('<path d="%s"/>' % d for lst in by_color.values() for d in lst)
    )
    svg2.extend(colored)
    ly = H - PAD + 14
    lx = PAD
    svg2.append(
        '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" font-size="13" '
        'font-weight="bold">Speed limit (km/h):</text>' % (lx, ly)
    )
    lx += 160
    for sp in sorted(by_color):
        n = both[sp]
        svg2.append('<rect x="%d" y="%d" width="14" height="14" fill="%s"/>'
                    % (lx, ly - 11, color_for(sp)))
        svg2.append(
            '<text x="%d" y="%d" fill="#e2e8f0" font-family="sans-serif" font-size="12">'
            '%d (%d)</text>' % (lx + 18, ly, sp, n)
        )
        lx += 92
    svg2.append('</svg>')

    html = html % {
        'n': len(feats), 'svg': '\n'.join(svg2),
        'W': W, 'H': H,
    }
    html_path = os.path.join(OUT_DIR, 'speed_limits_map.html')
    with open(html_path, 'w') as f:
        f.write(html)
    print('wrote', html_path)


if __name__ == '__main__':
    sys.exit(main())
