#!/usr/bin/env python3
"""Render a recorded NavBridge trip as a standalone HTML viewer.

Shows the GPS track (coloured by speed), the stops, and every voice
announcement as a marker + a clickable list, with the road value and the
EFFECTIVE limit side by side so a "voice said X while the screen showed Y"
report can be checked by eye.

Usage:
    python3 tool/trip_view.py                     # newest trip in docs/trips/device
    python3 tool/trip_view.py <trip.json>         # a specific trip
    python3 tool/trip_view.py <trip.json> -o out.html
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVICE_TRIPS = os.path.join(REPO, "docs/trips/device")

# Announcement kind → marker colour (matches the app's semantics).
KIND_COLOR = {
    "limit": "#1a73e8",
    "overspeed": "#d93025",
    "sign": "#f9ab00",
    "maneuver": "#9aa0a6",
    "gps": "#7b1fa2",
    "cam": "#e8710a",
    "voice": "#5f6368",
}
SPEED_BUCKETS = [
    (5, "#9aa0a6"),   # stopped / walking
    (30, "#1a73e8"),
    (50, "#188038"),
    (70, "#f9ab00"),
    (10 ** 9, "#d93025"),
]


def ms_of(value) -> int:
    """Accept ms epoch (str/int) or ISO-8601."""
    if value is None:
        return 0
    try:
        return int(value)
    except (TypeError, ValueError):
        pass
    try:
        return int(
            datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
            * 1000
        )
    except Exception:
        return 0


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    r = 6371000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = p2 - p1
    dl = math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)

    path_pts = []
    for e in raw.get("locations") or []:
        lat, lng = e.get("latitudeE7"), e.get("longitudeE7")
        if lat is None or lng is None:
            continue
        path_pts.append(
            {
                "t": ms_of(e.get("timestampMs") or e.get("timestamp")),
                "lat": lat / 1e7,
                "lng": lng / 1e7,
                "v": (e.get("velocity") or 0) * 3.6,  # m/s → km/h
                "acc": e.get("accuracy"),
                "street": e.get("street"),
                "hw": e.get("highway"),
                "road": e.get("speedLimit"),
                "eff": e.get("limitEffective"),
                "src": e.get("limitSource"),
            }
        )
    path_pts.sort(key=lambda p: p["t"])

    anns = []
    for a in raw.get("announcements") or []:
        anns.append(
            {
                "t": ms_of(a.get("time") or a.get("ms")),
                "lat": a.get("lat"),
                "lng": a.get("lng"),
                "kind": a.get("kind") or "voice",
                "text": a.get("text") or "",
            }
        )
    anns.sort(key=lambda a: a["t"])

    places = [
        {
            "lat": p.get("lat"),
            "lng": p.get("lng"),
            "name": p.get("name"),
            "entered": p.get("enteredAt"),
            "left": p.get("leftAt"),
        }
        for p in raw.get("places") or []
        if p.get("lat") is not None
    ]

    dist = sum(
        haversine_m((a["lat"], a["lng"]), (b["lat"], b["lng"]))
        for a, b in zip(path_pts[:-1], path_pts[1:])
    )
    speeds = [p["v"] for p in path_pts if p["v"] > 0]
    dur = ((path_pts[-1]["t"] - path_pts[0]["t"]) / 1000.0) if path_pts else 0

    return {
        "name": os.path.splitext(os.path.basename(path))[0],
        "path": path_pts,
        "announcements": anns,
        "places": places,
        "stats": {
            "fixes": len(path_pts),
            "km": round(dist / 1000.0, 2),
            "minutes": round(dur / 60.0, 1),
            "avgKmh": round(sum(speeds) / len(speeds), 1) if speeds else 0,
            "maxKmh": round(max(speeds), 1) if speeds else 0,
            "start": datetime.fromtimestamp(path_pts[0]["t"] / 1000).strftime(
                "%Y-%m-%d %H:%M:%S"
            )
            if path_pts
            else "",
            "end": datetime.fromtimestamp(path_pts[-1]["t"] / 1000).strftime(
                "%H:%M:%S"
            )
            if path_pts
            else "",
        },
    }


def num_in(text: str) -> int | None:
    """The spoken km/h number in an announcement, if any."""
    import re

    m = re.search(r"(\d+)\s*km/h", text)
    return int(m.group(1)) if m else None


def render(data: dict, out: str) -> None:
    # Flag lines where the spoken limit disagrees with the road / effective
    # value (the "voice vs screen" cases) — computed here, not in JS, so the
    # list can be filtered/summarised server-side too.
    for a in data["announcements"]:
        a["spoken"] = num_in(a["text"])
        near = nearest_fix(data["path"], a["t"])
        a["road"] = near["road"] if near else None
        a["eff"] = near["eff"] if near else None
        a["src"] = near["src"] if near else None
        a["street"] = near["street"] if near else None
        a["hw"] = near["hw"] if near else None
        sp = a["spoken"]
        a["mismatch"] = bool(
            sp is not None
            and ((a["road"] is not None and sp != a["road"])
                 or (a["eff"] is not None and sp != a["eff"]))
        )

    html = _TEMPLATE.replace("__DATA__", json.dumps(data, ensure_ascii=False))
    html = html.replace("__TITLE__", data["name"])
    html = html.replace("__KIND_COLORS__", json.dumps(KIND_COLOR))
    html = html.replace("__BUCKETS__", json.dumps(SPEED_BUCKETS))
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote", out)


def nearest_fix(path: list[dict], t: int) -> dict | None:
    if not path:
        return None
    lo, hi = 0, len(path) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if path[mid]["t"] < t:
            lo = mid + 1
        else:
            hi = mid
    best = path[lo]
    for c in (path[max(0, lo - 1)], path[lo], path[min(len(path) - 1, lo + 1)]):
        if abs(c["t"] - t) < abs(best["t"] - t):
            best = c
    return best


_TEMPLATE = r"""<!DOCTYPE html>
<html lang="vi"><head><meta charset="utf-8">
<title>NavBridge trip __TITLE__</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
 html,body{margin:0;height:100%;font:13px/1.45 -apple-system,Segoe UI,Roboto,sans-serif}
 #wrap{display:flex;height:100%}
 #map{flex:1;min-width:0}
 #side{width:430px;max-width:46vw;display:flex;flex-direction:column;border-left:1px solid #ddd}
 #hdr{padding:10px 12px;border-bottom:1px solid #eee;background:#fafafa}
 #hdr h1{margin:0 0 4px;font-size:15px}
 #stats{color:#555;font-size:12px}
 #legend{padding:6px 12px;border-bottom:1px solid #eee;background:#fff;font-size:12px}
 .chip{display:inline-block;padding:1px 7px;margin:2px 4px 2px 0;border-radius:9px;color:#fff;font-size:11px}
 #list{overflow:auto;flex:1}
 .row{padding:7px 12px;border-bottom:1px solid #f1f1f1;cursor:pointer}
 .row:hover{background:#f6f9ff}
 .row.sel{background:#e8f0fe}
 .row.warn{background:#fdecea}
 .row.warn.sel{background:#fad2cf}
 .t{color:#888;font-size:11px;font-variant-numeric:tabular-nums}
 .k{display:inline-block;padding:0 6px;border-radius:8px;color:#fff;font-size:10px;margin-left:6px;vertical-align:1px}
 .meta{color:#666;font-size:11px;margin-top:2px}
 .lr{color:#9aa0a6}
 .bad{color:#b3261e;font-weight:600}
</style></head><body>
<div id="wrap">
  <div id="map"></div>
  <div id="side">
    <div id="hdr"><h1 id="ttl"></h1><div id="stats"></div></div>
    <div id="legend"></div>
    <div id="list"></div>
  </div>
</div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const DATA = __DATA__;
const KIND_COLOR = __KIND_COLORS__;
const BUCKETS = __BUCKETS__;

const map = L.map('map');
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom:19, attribution:'© OpenStreetMap'}).addTo(map);

const pts = DATA.path;
document.getElementById('ttl').textContent = DATA.name.replace(/_/g,' ');
const s = DATA.stats;
document.getElementById('stats').textContent =
  `${s.start} → ${s.end} · ${s.km} km · ${s.minutes} min · ${s.fixes} fixes · `
  + `avg ${s.avgKmh} km/h · max ${s.maxKmh} km/h · ${DATA.places.length} stops`;

// --- track, coloured by speed bucket -------------------------------------
function bucketColor(v){
  for (const [lim,col] of BUCKETS) if (v < lim) return col;
  return '#d93025';
}
const bounds = L.latLngBounds([]);
for (let i=1;i<pts.length;i++){
  const a=pts[i-1], b=pts[i];
  L.polyline([[a.lat,a.lng],[b.lat,b.lng]],
    {color: bucketColor(b.v), weight: 5, opacity: .9}).addTo(map);
  bounds.extend([b.lat,b.lng]);
}
if (pts.length){
  bounds.extend([pts[0].lat,pts[0].lng]);
  L.circleMarker([pts[0].lat,pts[0].lng],{radius:7,color:'#fff',weight:2,fillColor:'#188038',fillOpacity:1})
    .addTo(map).bindPopup('Start '+s.start);
  const e=pts[pts.length-1];
  L.circleMarker([e.lat,e.lng],{radius:7,color:'#fff',weight:2,fillColor:'#d93025',fillOpacity:1})
    .addTo(map).bindPopup('End '+s.end);
  map.fitBounds(bounds,{padding:[20,20]});
} else { map.setView([10.7769,106.7009],13); }

// --- legend ---------------------------------------------------------------
const lg = document.getElementById('legend');
lg.innerHTML = `<b>Speed</b> ` + BUCKETS.slice(0,-1).map(([lim,c])=>
    `<span class="chip" style="background:${c}">&lt;${lim}</span>`).join('')
  + `<span class="chip" style="background:#d93025">70+</span>`
  + `<br><b>Voice</b> ` + Object.entries(KIND_COLOR).map(([k,c])=>
    `<span class="chip" style="background:${c}">${k}</span>`).join('')
  + `<br><span class="bad">đỏ nhạt</span> = số đọc KHÁC giá trị road/effective`;

// --- announcements --------------------------------------------------------
const markers = [];
const list = document.getElementById('list');
DATA.announcements.forEach((a,i)=>{
  if (a.lat==null) return;
  const col = KIND_COLOR[a.kind] || '#5f6368';
  const m = L.circleMarker([a.lat,a.lng],{radius:5,color:'#fff',weight:1.5,fillColor:col,fillOpacity:1})
    .addTo(map);
  markers[i]=m;
  const hhmmss = new Date(a.t).toTimeString().slice(0,8);
  let lim = '';
  if (a.road!=null || a.eff!=null)
    lim = `<span class="lr">road ${a.road ?? '-'} · eff ${a.eff ?? '-'}${a.src? ' ('+a.src+')':''}</span>`;
  const row = document.createElement('div');
  row.className = 'row' + (a.mismatch ? ' warn' : '');
  row.innerHTML = `<div><span class="t">${hhmmss}</span><span class="k" style="background:${col}">${a.kind}</span></div>
    <div>${a.text}</div>
    <div class="meta">${a.street ?? ''}${a.hw? ' · '+a.hw:''}</div>
    ${lim? '<div class="meta">'+lim+'</div>':''}`;
  row.onclick = ()=>{
    map.setView([a.lat,a.lng],17);
    m.openPopup();
    [...list.children].forEach(r=>r.classList.remove('sel'));
    row.classList.add('sel');
  };
  m.bindPopup(`<b>${a.kind}</b> ${hhmmss}<br>${a.text}<br>${lim}`);
  list.appendChild(row);
});
</script>
</body></html>
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("trip", nargs="?", help="trip JSON (default: newest in "
                                           "docs/trips/device)")
    ap.add_argument("-o", "--out", help="output HTML")
    args = ap.parse_args()

    trip = args.trip
    if not trip:
        cands = sorted(glob.glob(os.path.join(DEVICE_TRIPS, "*.json")))
        if not cands:
            print("no trips in", DEVICE_TRIPS)
            return 1
        trip = cands[-1]
    data = load(trip)
    out = args.out or os.path.join(
        REPO, "docs", "trip_" + data["name"] + ".html"
    )
    render(data, out)
    print(
        f"  {data['stats']['fixes']} fixes · {data['stats']['km']} km · "
        f"{len(data['announcements'])} announcements · "
        f"{sum(1 for a in data['announcements'] if a.get('mismatch'))} spoken-vs-road mismatches"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
