#!/usr/bin/env python3
"""Visualise a recorded NavBridge trip as a self-contained HTML page.

Shows, on one Leaflet map plus a synced timeline:
  * the GPS track, coloured by speed (and the raw vs corrected speed)
  * every recorded announcement at its position — coloured by kind
  * the turn-restriction signs (no_left / no_right / no_u_turn) that lie close
    to the track, so a wrong sign on the map can be traced to its source row

Usage:
    python3 tools/trips/visualize_trip.py [trip.json] [--out out.html]
                                          [--near-m 60] [--open]

With no argument it picks the newest trip in docs/trips/ then assets/trips/.
"""
import argparse
import glob
import json
import math
import os
import re
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SIGNS_JSON = os.path.join(ROOT, "assets", "offline_map", "vietnam_signs.json")
SIGN_KINDS = ("no_left_turn", "no_right_turn", "no_u_turn",
              "no_left_uturn", "no_right_uturn", "no_passing", "stop",
              "give_way", "populated", "populated_end", "end_prohibitions")

# kind -> colour used for both the map marker and the timeline chip
KIND_COLOR = {
    "maneuver": "#3b82f6",
    "speed": "#ef4444",
    "sign": "#22c55e",
    "camera": "#f59e0b",
    "zone": "#a855f7",
    "poi": "#14b8a6",
    "arrival": "#e11d48",
    "ai": "#64748b",
}
SIGN_COLOR = {
    "no_left_turn": "#dc2626",
    "no_right_turn": "#ea580c",
    "no_u_turn": "#7c3aed",
    "no_left_uturn": "#b91c1c",
    "no_right_uturn": "#c2410c",
}


def hav(a_lat, a_lng, b_lat, b_lng):
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lng - a_lng)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(x))


def newest_trip():
    cands = []
    for d in (os.path.join(ROOT, "docs", "trips"),
              os.path.join(ROOT, "assets", "trips"),
              os.path.join(ROOT, "docs"), os.path.join(ROOT, "update")):
        if not os.path.isdir(d):
            continue
        for pat in ("*.json", os.path.join("**", "*.json")):
            cands += [p for p in glob.glob(os.path.join(d, pat), recursive=True)
                      if "backup" in os.path.basename(p).lower()
                      or "Chuyến" in os.path.basename(p)
                      or "Chuyen" in os.path.basename(p)]
    cands = [p for p in cands if "vietnam_signs" not in p]

    def trip_key(p):
        """Order by the timestamp in the NAME (YYYY-MM-DD_HHMMSS), not mtime.

        Trips pulled off the phone with adb all land with the same mtime, so
        mtime-based ordering picks an arbitrary one. The recorded filename
        carries the real start time.
        """
        m = re.search(r"(\d{4})-(\d{2})-(\d{2})_(\d{6})", os.path.basename(p))
        if m:
            return (f"{m.group(1)}-{m.group(2)}-{m.group(3)}", m.group(4))
        m = re.search(r"(\d{4}-\d{2}-\d{2})", os.path.basename(p))
        return (m.group(1) if m else "", "") or ("", "")

    hits = sorted(set(cands), key=trip_key)
    if hits:
        return hits[-1]
    sys.exit("no trip JSON found")


def load_trip(path):
    d = json.load(open(path))
    label = os.path.basename(path)
    # The app's "share trips backup" export wraps every saved trip in a
    # `trips: [{file, data}]` array. Unwrap it and use the NEWEST trip inside,
    # so pointing this at a backup just works.
    if isinstance(d, dict) and isinstance(d.get("trips"), list) and d["trips"]:
        inner = [t for t in d["trips"] if isinstance(t, dict) and t.get("data")]
        if inner:
            def newest_key(t):
                data = t["data"]
                ms = 0
                for coll in ("locations", "announcements"):
                    for e in (data.get(coll) or []):
                        try:
                            ms = max(ms, int(e.get("timestampMs") or 0))
                        except (TypeError, ValueError):
                            pass
                # Fall back to the recorded filename (starts with the date).
                return (ms, t.get("file") or "")
            best = max(inner, key=newest_key)
            print(f"backup    : {label} -> {len(inner)} trip(s) inside")
            print(f"newest    : {best.get('file')}")
            label = best.get("file") or label
            d = best["data"]
    locs = []
    for p in d.get("locations", []):
        try:
            locs.append({
                "t": p["timestamp"],
                "ms": int(p.get("timestampMs") or 0),
                "lat": p["latitudeE7"] / 1e7,
                "lng": p["longitudeE7"] / 1e7,
                "kmh": (p.get("velocity") or 0) * 3.6,
                "acc": p.get("accuracy"),
                "head": p.get("heading"),
                "src": p.get("source"),
            })
        except (KeyError, TypeError):
            continue
    anns = []
    for a in d.get("announcements", []):
        anns.append({
            "t": a.get("time"),
            "ms": int(a.get("timestampMs") or 0),
            "lat": a.get("lat"), "lng": a.get("lng"),
            "kind": a.get("kind") or "?",
            "text": a.get("text") or "",
        })
    return locs, anns, label


def signs_near(locs, max_m):
    if not os.path.exists(SIGNS_JSON):
        return []
    doc = json.load(open(SIGNS_JSON))
    allsigns = doc["signs"] if isinstance(doc, dict) else doc
    cell = 0.003
    grid = {}
    for i, s in enumerate(allsigns):
        grid.setdefault((int(s["lat"] / cell), int(s["lng"] / cell)), []).append(i)
    out, seen = [], set()
    for p in locs:
        gi, gj = int(p["lat"] / cell), int(p["lng"] / cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((gi + dx, gj + dy), ()):
                    s = allsigns[i]
                    k = (round(s["lat"], 5), round(s["lng"], 5))
                    if k in seen:
                        continue
                    d = hav(p["lat"], p["lng"], s["lat"], s["lng"])
                    if d <= max_m:
                        seen.add(k)
                        out.append({
                            "lat": s["lat"], "lng": s["lng"],
                            "kind": s.get("kind"), "name": s.get("name"),
                            "value": s.get("value"), "source": s.get("source"),
                            "d": round(d, 1),
                        })
    out.sort(key=lambda s: s["d"])
    return out


HTML = """<!DOCTYPE html>
<html lang="vi"><head><meta charset="utf-8">
<title>NavBridge trip __DATE__</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
 html,body{margin:0;height:100%;font:13px/1.45 -apple-system,Segoe UI,Roboto,sans-serif}
 #wrap{display:flex;height:100%}
 #map{flex:1;min-width:0}
 #side{width:420px;max-width:45vw;display:flex;flex-direction:column;border-left:1px solid #ddd}
 #hdr{padding:10px 12px;border-bottom:1px solid #eee;background:#fafafa}
 #hdr h1{margin:0 0 4px;font-size:15px}
 #stats{color:#555;font-size:12px}
 #legend{padding:6px 12px;border-bottom:1px solid #eee;background:#fff;font-size:12px}
 .chip{display:inline-block;padding:1px 6px;margin:2px 4px 2px 0;border-radius:9px;
       color:#fff;font-size:11px}
 #list{overflow:auto;flex:1}
 .row{padding:7px 12px;border-bottom:1px solid #f1f1f1;cursor:pointer}
 .row:hover{background:#f6f9ff}
 .row.sel{background:#e8f0fe}
 .t{color:#888;font-size:11px;font-variant-numeric:tabular-nums}
 .k{display:inline-block;padding:0 6px;border-radius:8px;color:#fff;font-size:10px;
    margin-left:6px;vertical-align:1px}
 .txt{margin-top:2px}
 .meta{color:#999;font-size:11px;margin-top:1px}
</style></head><body>
<div id="wrap">
  <div id="map"></div>
  <div id="side">
    <div id="hdr">
      <h1>Chuyến đi __DATE__</h1>
      <div id="stats"></div>
    </div>
    <div id="legend"></div>
    <div id="list"></div>
  </div>
</div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const TRACK = __TRACK__;
const ANNS  = __ANNS__;
const SIGNS = __SIGNS__;
const SPANS = __SPANS__;
const map = L.map('map');
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom:19, attribution:'© OpenStreetMap'}).addTo(map);

// --- track: one segment per GPS fix so colour = speed -------------------
const maxKmh = Math.max(1, ...TRACK.map(p=>p.kmh));
function col(v){ const r = v/maxKmh;
  return `hsl(${(1-r)*120},85%,45%)`; }
for (let i=1;i<TRACK.length;i++){
  const a=TRACK[i-1], b=TRACK[i];
  L.polyline([[a.lat,a.lng],[b.lat,b.lng]],
    {color:col(b.kmh), weight:5, opacity:.9})
   .bindPopup(`${b.kmh.toFixed(0)} km/h · ${b.t}<br>acc ${b.acc||'?'} m · ${b.src||''}`)
   .addTo(map);
}
const start = TRACK[0], end = TRACK[TRACK.length-1];
L.circleMarker([start.lat,start.lng],{radius:7,color:'#fff',weight:2,
  fillColor:'#16a34a',fillOpacity:1}).bindPopup('Start').addTo(map);
L.circleMarker([end.lat,end.lng],{radius:7,color:'#fff',weight:2,
  fillColor:'#dc2626',fillOpacity:1}).bindPopup('End').addTo(map);

// --- signs near the track ----------------------------------------------
const signLayer = L.layerGroup();
SIGNS.forEach(s=>{
  L.circleMarker([s.lat,s.lng],{radius:6,color:'#111',weight:1,
    fillColor:(__SIGNCOL__)[s.kind]||'#555',fillOpacity:.95})
   .bindPopup(`<b>${s.name||s.kind}</b><br>${s.kind}`+
     (s.value?` · ${s.value} km/h`:'')+`<br>source ${s.source||'?'}`+
     `<br>${s.d} m from track`).addTo(signLayer);
});
if (SIGNS.length) signLayer.addTo(map);

// --- announcements ------------------------------------------------------
const annLayer = L.layerGroup().addTo(map);
ANNS.forEach((a,i)=>{
  if (a.lat==null) return;
  const c = (__KINDCOL__)[a.kind]||'#64748b';
  L.circleMarker([a.lat,a.lng],{radius:5,color:'#fff',weight:1.5,
    fillColor:c,fillOpacity:1})
   .bindPopup(`<b>${a.kind}</b><br>${a.t||''}<br>${(a.text||'')
     .replace(/[<>&]/g,'')}`).addTo(annLayer);
});

const all = L.featureGroup([annLayer, signLayer]);
try { map.fitBounds(all.getBounds().pad(.15)); }
catch(e){ map.setView([TRACK[0].lat,TRACK[0].lng], 15); }

// --- timeline -----------------------------------------------------------
const list = document.getElementById('list');
const rows = [];
ANNS.forEach((a,i)=>{
  const d = document.createElement('div');
  d.className='row';
  const c = (__KINDCOL__)[a.kind]||'#64748b';
  const hh = a.t ? a.t.slice(11,19) : '';
  d.innerHTML = `<div class="t">${hh}<span class="k" style="background:${c}">`
    + `${a.kind}</span></div><div class="txt">${(a.text||'')
      .replace(/[<>&]/g,'')}</div>`
    + (a.spd!=null?`<div class="meta">${a.spd}</div>`:'');
  d.onclick = ()=>{
    rows.forEach(r=>r.classList.remove('sel')); d.classList.add('sel');
    if (a.lat!=null){ map.setView([a.lat,a.lng],17); }
    const target = i;
    let best=null, bd=1e9;
    ANNS.forEach((x,j)=>{ if(x.lat==null)return;
      const dd=Math.abs(((x.ms||0)-(a.ms||0))); if(dd<bd){bd=dd;best=x;} });
    if(best) map.setView([best.lat,best.lng],17);
  };
  list.appendChild(d); rows.push(d);
});

const stats = document.getElementById('stats');
const dur = (TRACK.length>1)
  ? ((TRACK[TRACK.length-1].ms-TRACK[0].ms)/60000).toFixed(1) : '0';
stats.textContent = `${TRACK.length} GPS fixes · ${dur} min · `
  + `${ANNS.length} announcements · ${SIGNS.length} signs near track`;

const legend = document.getElementById('legend');
const counts = {};
ANNS.forEach(a=>counts[a.kind]=(counts[a.kind]||0)+1);
legend.innerHTML = '<b>Announcements</b><br>' + Object.keys(counts)
  .map(k=>`<span class="chip" style="background:${(__KINDCOL__)[k]||'#64748b'}">`
    + `${k} ${counts[k]}</span>`).join('')
  + '<br><br><b>Signs near track (top)</b><br>' + SPANS;
map.on('click', ()=>{});
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trip", nargs="?", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--near-m", type=float, default=60.0)
    args = ap.parse_args()

    path = args.trip or newest_trip()
    locs, anns, label = load_trip(path)
    if not locs:
        sys.exit(f"no GPS fixes in {path}")
    signs = signs_near(locs, args.near_m)
    # Date for the title: prefer the recorded file name, else the first fix.
    m = re.search(r"(\d{4}-\d{2}-\d{2})", label)
    date = m.group(1) if m else (locs[0]["t"] or "")[:10]
    stamp = re.search(r"(\d{4}-\d{2}-\d{2})_(\d{6})", label)
    slug = f"{stamp.group(1)}_{stamp.group(2)}" if stamp else date

    # attach the speed closest in time to each announcement
    bytime = sorted(locs, key=lambda p: p["ms"])
    for a in anns:
        best, bd = None, 1 << 62
        for p in bytime:
            d = abs(p["ms"] - a["ms"])
            if d < bd:
                bd, best = d, p
        if best is not None and bd < 15000:
            a["spd"] = f"{best['kmh']:.0f} km/h @ fix"

    spans = []
    c = Counter(s["kind"] for s in signs)
    for k, n in c.most_common(10):
        col = SIGN_COLOR.get(k, "#555")
        spans.append(f'<span class="chip" style="background:{col}">{k} {n}</span>')
    spans.append(f'<span class="chip" style="background:#555">total {len(signs)}</span>')

    trip_pts = [{k: (round(v, 6) if isinstance(v, float) else v)
                 for k, v in p.items()} for p in locs]
    html = (HTML
            .replace("__DATE__", date)
            .replace("__TRACK__", json.dumps(trip_pts, ensure_ascii=False))
            .replace("__ANNS__", json.dumps(anns, ensure_ascii=False))
            .replace("__SIGNS__", json.dumps(signs, ensure_ascii=False))
            .replace("__SPANS__", json.dumps("".join(spans), ensure_ascii=False))
            .replace("__KINDCOL__", json.dumps(KIND_COLOR))
            .replace("__SIGNCOL__", json.dumps(SIGN_COLOR)))

    out = args.out or os.path.join(ROOT, "docs", f"trip_{slug}.html")
    with open(out, "w") as fh:
        fh.write(html)
    print(f"trip      : {os.path.relpath(path, ROOT)}")
    print(f"gps fixes : {len(locs)}")
    print(f"announce  : {len(anns)}  {dict(Counter(a['kind'] for a in anns))}")
    print(f"signs<={args.near_m:.0f}m: {len(signs)}  {dict(c)}")
    print(f"wrote     : {os.path.relpath(out, ROOT)}  ({os.path.getsize(out)} bytes)")
    for s in signs[:12]:
        print(f"   {s['d']:6.1f} m  {s['kind']:<16} {s['name']}  [{s['source']}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
