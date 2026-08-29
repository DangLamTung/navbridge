#!/usr/bin/env python3
"""Emit docs/gps_before_after.html — speed + location graphs, before vs after.

Before  = raw GPS (position-derived implied speed, per-fix jump distance)
After   = CarFilter (complementary filter) + route snap + OutlierGate
          (rejected bursts marked with a red '✕').
Self-contained: no CDN, pure <canvas>.
"""
import json
import math
import os

R = 6371000.0
OUT = os.path.join(os.path.dirname(__file__), '..', 'docs', 'gps_before_after.html')


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def dm_flat(a, b):
    md = 111320.0
    ml = md * math.cos(a[0] * math.pi / 180)
    dLa = (b[0] - a[0]) * md
    dLo = (b[1] - a[1]) * ml
    return math.sqrt(dLa * dLa + dLo * dLo)


def gate(prev, pos, dt, smooth):
    if prev is None or dt is None or dt <= 0:
        return True, smooth
    d = dm_flat(prev, pos)
    allowed = max(smooth, 5.0) * dt * 3.0
    if d > allowed:
        return False, smooth
    smooth = 0.5 * (d / dt) + 0.5 * smooth
    return True, smooth


def ang_diff(a, b):
    d = (a - b) % 360
    return d if d <= 180 else 360 - d


def bearing_deg(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def strict_heading_after(fixes, raw_headings):
    """Exact port of StrictHeading.update (lib/core/heading_filter.dart)."""
    heading = None
    pending = None
    pending_at = None
    last = None
    out = []
    for (lat, lng, ts), raw in zip(fixes, raw_headings):
        travel = None
        if last is not None and dist(last[:2], (lat, lng)) >= 2.0:
            travel = bearing_deg(last[:2], (lat, lng))
        last = (lat, lng, ts)
        if travel is None:
            if heading is None:
                heading = raw  # seed once from the compass
        else:
            if heading is None:
                heading = travel
            else:
                d = ang_diff(travel, heading)
                if d <= 40:
                    pending = pending_at = None
                    heading = travel
                elif (pending is not None and pending_at is not None
                      and (ts - pending_at) / 1000.0 < 3.0
                      and ang_diff(travel, pending) <= 40):
                    pending = pending_at = None
                    heading = travel
                else:
                    pending, pending_at = travel, ts
        out.append(heading)
    return out


def compute(path):
    d = json.load(open(path))
    fixes = [(f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7, int(f['timestampMs'])) for f in d['locations']]
    logged_h = [f.get('heading') for f in d['locations']]
    speed_raw, speed_filt, jump_raw, jump_filt, rej = [], [], [], [], []
    car_spd = 0.0
    car_pos = None
    prev_filt = None
    g_smooth = 0.0
    last = None
    last_raw = None
    for i, (lat, lng, ts) in enumerate(fixes):
        pos = (lat, lng)
        dt_g = None if last is None else (ts - last[2]) / 1000.0
        ok, g_smooth = gate(None if last is None else last[:2], pos, dt_g, g_smooth)
        if ok:
            last = (lat, lng, ts)
        dt_r = 0.0
        dm = 0.0
        if last_raw is not None:
            dt_r = (ts - last_raw[2]) / 1000.0
            dm = dist(last_raw[:2], pos)
            if dt_r > 0:
                car_spd = 0.3 * (dm / dt_r) + 0.7 * car_spd
            if car_pos is not None and 0 < dt_r < 1.0 and car_spd > 0.3:
                car_pos = (0.8 * lat + 0.2 * car_pos[0], 0.8 * lng + 0.2 * car_pos[1])
            else:
                car_pos = pos
        else:
            car_pos = pos
        last_raw = (lat, lng, ts)
        speed_raw.append(round(dm / dt_r * 3.6, 1) if dt_r > 0 else 0.0)
        speed_filt.append(round(car_spd * 3.6, 1))
        jump_raw.append(round(dm, 1))
        jump_filt.append(round(dist(prev_filt, car_pos), 1) if prev_filt is not None else 0.0)
        prev_filt = car_pos
        rej.append(1 if not ok else 0)

    def fill_prev(a):
        out, last = [], None
        for v in a:
            if v is not None:
                last = v
            out.append(last)
        return [round(v, 0) if v is not None else 0.0 for v in out]

    h_log = fill_prev(list(logged_h))
    h_aft = fill_prev(list(strict_heading_after(fixes, logged_h)))

    # Trim the leading NO-GPS warm-up: before the first real movement
    # (per-fix displacement >= 3 m) the phone is stationary with a poor fix —
    # speed/heading there are meaningless. Cut from the first moving fix.
    start = next((i for i, j in enumerate(jump_raw) if j >= 3.0), 0)
    if start > 0:
        speed_raw = speed_raw[start:]
        speed_filt = speed_filt[start:]
        jump_raw = jump_raw[start:]
        jump_filt = jump_filt[start:]
        rej = rej[start:]
        h_log = h_log[start:]
        h_aft = h_aft[start:]

    return {'n': len(fixes), 'start': start, 'speed_raw': speed_raw, 'speed_filt': speed_filt,
            'jump_raw': jump_raw, 'jump_filt': jump_filt, 'rej': rej,
            'h_log': h_log, 'h_aft': h_aft}


def js_arr(a):
    return '[' + ','.join(str(x) for x in a) + ']'


def main():
    path = os.path.join(os.path.dirname(__file__), '..', 'test', 'assets', 'trips', '2026-08-27_172432_Chuyến_đi.json')
    d = compute(path)

    html = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>NavBridge GPS — before vs after (trip 17:24)</title>
<style>
  body{margin:0;background:#0f172a;color:#e2e8f0;font-family:system-ui,sans-serif}
  h1{font-size:15px;padding:10px 14px 0;margin:0}
  h2{font-size:13px;padding:12px 14px 4px;margin:0;color:#94a3b8}
  .card{margin:8px 14px;background:#1e293b;border:1px solid #334155;border-radius:10px;padding:6px}
  canvas{width:100%;height:260px;display:block}
  .legend{font-size:12px;padding:4px 12px 8px}
  .legend span{display:inline-block;margin-right:14px}
  .sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
  .stats{font-size:12px;color:#94a3b8;padding:0 14px 8px}
  code{background:#0b1220;padding:1px 5px;border-radius:4px}
</style>
</head>
<body>
<h1>NavBridge GPS — trip 17:24 (17:24–17:37) — before (raw GPS) vs after (CarFilter + OutlierGate)</h1>
<div class="stats">__NF__ fixes · __REJ__ outlier fix rejected (the 130 km/h burst) · filtered max speed __MAXF__ km/h vs raw __MAXR__ km/h</div>

<div class="card">
  <h2>Speed (km/h) per GPS fix — raw vs filtered</h2>
  <canvas id="cSpeed"></canvas>
  <div class="legend">
    <span><span class="sw" style="background:#ef4444"></span>Before — raw GPS</span>
    <span><span class="sw" style="background:#22c55e"></span>After — CarFilter</span>
    <span><span class="sw" style="background:#f59e0b"></span>Rejected outlier</span>
  </div>
</div>

<div class="card">
  <h2>Position jump (metres between fixes) — raw vs filtered</h2>
  <canvas id="cJump"></canvas>
  <div class="legend">
    <span><span class="sw" style="background:#ef4444"></span>Before — raw jump</span>
    <span><span class="sw" style="background:#22c55e"></span>After — filtered jump</span>
  </div>
</div>

<div class="card">
  <h2>Heading (degrees) per fix — logged (spins while parked) vs StrictHeading (holds)</h2>
  <canvas id="cHead"></canvas>
  <div class="legend">
    <span><span class="sw" style="background:#ef4444"></span>Before — logged heading</span>
    <span><span class="sw" style="background:#22c55e"></span>After — StrictHeading</span>
  </div>
</div>

<script>
const SR = %(sr)s, SF = %(sf)s, JR = %(jr)s, JF = %(jf)s, REJ = %(rej)s, N = %(n)d;
const HL = %(hl)s, HA = %(ha)s;
function chart(id, raw, filt, rej, ylab){
  const cv=document.getElementById(id), ctx=cv.getContext('2d');
  const dpr=window.devicePixelRatio||1, W=cv.clientWidth, H=cv.clientHeight;
  cv.width=W*dpr; cv.height=H*dpr; ctx.scale(dpr,dpr);
  const padL=46, padB=22, padT=10, padR=10;
  let maxV=0; for(const a of [raw,filt]) for(const v of a) maxV=Math.max(maxV,v);
  maxV=Math.ceil(maxV*1.1/10)*10; if(maxV<=0)maxV=10;
  const iw=W-padL-padR, ih=H-padT-padB;
  // grid + axes
  ctx.strokeStyle='#334155'; ctx.fillStyle='#94a3b8'; ctx.font='10px sans-serif';
  for(let g=0;g<=4;g++){ const y=padT+ih*g/4, val=maxV*(1-g/4);
    ctx.beginPath(); ctx.moveTo(padL,y); ctx.lineTo(W-padR,y); ctx.stroke();
    ctx.fillText(val.toFixed(0), 4, y+3); }
  ctx.fillText(ylab, W-padR-30, padT-4);
  ctx.fillText('0', 2, H-padB+3); ctx.fillText('fix #'+N, W-padR-34, H-padB+14);
  function line(arr,color,w){ ctx.strokeStyle=color; ctx.lineWidth=w;
    ctx.beginPath();
    for(let i=0;i<N;i++){ const x=padL+iw*i/(N-1), y=padT+ih*(1-arr[i]/maxV);
      i===0?ctx.moveTo(x,y):ctx.lineTo(x,y); } ctx.stroke(); }
  line(raw,'#ef4444',1.2); line(filt,'#22c55e',1.6);
  // rejected marks
  ctx.fillStyle='#f59e0b';
  for(let i=0;i<N;i++) if(rej[i]){ const x=padL+iw*i/(N-1);
    ctx.fillRect(x-1.5,padT-2,3,ih+2); }
}
chart('cSpeed', SR, SF, REJ, 'km/h');
chart('cJump', JR, JF, [], 'm');
chart('cHead', HL, HA, [], 'deg');
</script>
</body>
</html>
"""

    html = html.replace('%(sr)s', js_arr(d['speed_raw']))
    html = html.replace('%(sf)s', js_arr(d['speed_filt']))
    html = html.replace('%(jr)s', js_arr(d['jump_raw']))
    html = html.replace('%(jf)s', js_arr(d['jump_filt']))
    html = html.replace('%(rej)s', js_arr(d['rej']))
    html = html.replace('%(hl)s', js_arr(d['h_log']))
    html = html.replace('%(ha)s', js_arr(d['h_aft']))
    html = html.replace('%(n)d', str(d['n']))

    rej_count = sum(d['rej'])
    max_raw = max(d['speed_raw'])
    max_filt = max(d['speed_filt'])
    html = (html
            .replace('__NF__', str(d['n']))
            .replace('__REJ__', str(rej_count))
            .replace('__MAXF__', '%.0f' % max_filt)
            .replace('__MAXR__', '%.0f' % max_raw))

    with open(OUT, 'w') as f:
        f.write(html)
    print('wrote', OUT, '(%.0f KB)' % (os.path.getsize(OUT) / 1024))
    print('rejected fixes:', rej_count, ' max speed raw=%.0f filt=%.0f km/h' % (max_raw, max_filt))

    # Also emit compact ECharts-ready specs (downsampled to ~160 pts) for chat.
    def ds(a, m=160):
        if len(a) <= m:
            return a
        step = (len(a) - 1) / (m - 1)
        return [a[int(i * step)] for i in range(m)]

    xs = list(range(min(d['n'], 160)))
    srx, sfx = ds(d['speed_raw']), ds(d['speed_filt'])
    jrx, jfx = ds(d['jump_raw']), ds(d['jump_filt'])
    hlog, haft = ds(d['h_log']), ds(d['h_aft'])
    xr = list(range(len(srx)))
    spec_speed = {
        'title': {'text': 'Speed (km/h) per fix — trip 17:24', 'left': 'center', 'textStyle': {'color': '#e2e8f0'}},
        'tooltip': {'trigger': 'axis'},
        'legend': {'data': ['Before (raw GPS)', 'After (CarFilter)'], 'top': 28, 'textStyle': {'color': '#e2e8f0'}},
        'grid': {'left': 46, 'right': 16, 'top': 64, 'bottom': 30},
        'xAxis': {'type': 'category', 'name': 'fix #', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8'}, 'axisLine': {'lineStyle': {'color': '#475569'}}},
        'yAxis': {'type': 'value', 'name': 'km/h', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8'}, 'splitLine': {'lineStyle': {'color': '#1e293b'}}},
        'series': [
            {'name': 'Before (raw GPS)', 'type': 'line', 'showSymbol': False, 'data': srx,
             'lineStyle': {'color': '#ef4444', 'width': 1.4}, 'itemStyle': {'color': '#ef4444'}},
            {'name': 'After (CarFilter)', 'type': 'line', 'showSymbol': False, 'data': sfx,
             'lineStyle': {'color': '#22c55e', 'width': 2}, 'itemStyle': {'color': '#22c55e'}},
        ],
    }
    spec_jump = {
        'title': {'text': 'Position jump (m between fixes) — trip 17:24', 'left': 'center', 'textStyle': {'color': '#e2e8f0'}},
        'tooltip': {'trigger': 'axis'},
        'legend': {'data': ['Before (raw jump)', 'After (filtered jump)'], 'top': 28, 'textStyle': {'color': '#e2e8f0'}},
        'grid': {'left': 46, 'right': 16, 'top': 64, 'bottom': 30},
        'xAxis': {'type': 'category', 'name': 'fix #', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8'}, 'axisLine': {'lineStyle': {'color': '#475569'}}},
        'yAxis': {'type': 'value', 'name': 'm', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8'}, 'splitLine': {'lineStyle': {'color': '#1e293b'}}},
        'series': [
            {'name': 'Before (raw jump)', 'type': 'line', 'showSymbol': False, 'data': jrx,
             'lineStyle': {'color': '#ef4444', 'width': 1.4}, 'areaStyle': {'color': 'rgba(239,68,68,0.15)'}},
            {'name': 'After (filtered jump)', 'type': 'line', 'showSymbol': False, 'data': jfx,
             'lineStyle': {'color': '#22c55e', 'width': 2}, 'areaStyle': {'color': 'rgba(34,197,94,0.12)'}},
        ],
    }
    import json as _json
    with open('/tmp/echarts_speed.json', 'w') as f:
        _json.dump(spec_speed, f, indent=1)
    with open('/tmp/echarts_jump.json', 'w') as f:
        _json.dump(spec_jump, f, indent=1)

    spec_head = {
        'title': {'text': 'Heading (deg) per fix — trip 17:24', 'left': 'center', 'textStyle': {'color': '#e2e8f0'}},
        'tooltip': {'trigger': 'axis'},
        'legend': {'data': ['Before (logged, spins parked)', 'After (StrictHeading)'], 'top': 28, 'textStyle': {'color': '#e2e8f0'}},
        'grid': {'left': 46, 'right': 16, 'top': 64, 'bottom': 30},
        'xAxis': {'type': 'category', 'name': 'fix #', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8', 'show': False}, 'axisLine': {'lineStyle': {'color': '#475569'}}},
        'yAxis': {'type': 'value', 'min': 0, 'max': 360, 'name': 'deg', 'nameTextStyle': {'color': '#94a3b8'},
                  'axisLabel': {'color': '#94a3b8'}, 'splitLine': {'lineStyle': {'color': '#1e293b'}}},
        'series': [
            {'name': 'Before (logged, spins parked)', 'type': 'line', 'showSymbol': False, 'data': hlog,
             'lineStyle': {'color': '#ef4444', 'width': 1.3}, 'itemStyle': {'color': '#ef4444'}},
            {'name': 'After (StrictHeading)', 'type': 'line', 'showSymbol': False, 'data': haft,
             'lineStyle': {'color': '#22c55e', 'width': 2}, 'itemStyle': {'color': '#22c55e'}},
        ],
        'backgroundColor': '#0f172a',
    }
    with open('/tmp/echarts_heading.json', 'w') as f:
        _json.dump(spec_head, f, indent=1)
    print('wrote /tmp/echarts_speed.json + /tmp/echarts_jump.json + /tmp/echarts_heading.json')


if __name__ == '__main__':
    main()
