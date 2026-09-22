#!/usr/bin/env python3
"""Local server for recorded NavBridge trips — no HTML file to rebuild.

`tool/trip_view.py` writes a self-contained page with the trip JSON embedded in
it, so every trip means another build, another file, and a page that silently
goes stale when the JSON changes. This server renders the SAME viewer in memory
per request and serves the JSON next to it, so:

    http://127.0.0.1:8770/                     newest trip, rendered on the fly
    http://127.0.0.1:8770/?trip=<name>         one specific trip
    http://127.0.0.1:8770/api/trips            every trip, with quick stats
    http://127.0.0.1:8770/api/trip/<name>.json the raw trip JSON (for tooling)
    http://127.0.0.1:8770/api/pull             pull them off the phone (adb)
    http://127.0.0.1:8770/api/audit            tool/check_voice_calls.py output

The page gets a small picker bar (trip list + "Pull from phone"), so switching
trips is a dropdown, not a command line.

Usage:
    python3 tool/trip_server.py                 # docs/trips/device, port 8770
    python3 tool/trip_server.py --port 9000 --device 11046644BW000992
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trip_view  # noqa: E402  (shares the viewer + the trip loader)

REPO = trip_view.REPO
# Where the app mirrors its trips on the phone — readable by adb on a RELEASE
# build (no `run-as`, no root), which is why pulling is a plain `adb pull`.
PHONE_TRIPS = "/sdcard/Android/data/com.navbridge.app/files/trips"

# The app's PRIMARY posted-limit source: 1.03M Waze WME segments, each with a
# per-direction limit (assets/offline_map/waze_segments.bin, format 'WZSG').
# Serving them to the map is how you SEE the coverage the app has to work with —
# and which stretches have no posted data at all and fall back to a road-form
# guess. Decoded by tool/waze_segments.py (the same reader trip_truth.py uses).
SEGMENTS_BIN = os.path.join(REPO, "assets", "offline_map", "waze_segments.bin")

_lock = threading.Lock()
_index: dict[str, dict] = {}  # name -> {size, mtime, stats...}
_segs = None  # decoded WZSG layer, loaded on first /api/segments request


def adb_path() -> str | None:
    for cand in (
        os.environ.get("ADB"),
        shutil.which("adb"),
        os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
    ):
        if cand and os.path.exists(cand):
            return cand
    return None


def first_device(adb: str) -> str | None:
    try:
        out = subprocess.run(
            [adb, "devices"], capture_output=True, text=True, timeout=15
        ).stdout
    except Exception:
        return None
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            return parts[0]
    return None


def trips_dir_files(directory: str) -> list[str]:
    return sorted(glob.glob(os.path.join(directory, "*.json")))


def safe_name(name: str) -> str | None:
    """Reject anything that could escape the trips directory."""
    name = unquote(name or "").strip()
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        return None
    if name != os.path.basename(name) or not name.endswith(".json"):
        return None
    return name


def quick_stats(path: str) -> dict:
    """Fixes / km / announcements — the numbers worth showing in the picker."""
    try:
        data = trip_view.load(path)
    except Exception as exc:  # a half-written file must not kill the server
        return {"error": str(exc)}
    anns = data.get("announcements") or []
    st = data.get("stats") or {}
    return {
        "fixes": st.get("fixes", 0),
        "km": st.get("km", 0),
        "minutes": st.get("minutes", 0),
        "avgKmh": st.get("avgKmh", 0),
        "announcements": len(anns),
        "maneuvers": sum(1 for a in anns if a.get("kind") == "maneuver"),
        "started": st.get("start", ""),
        "ended": st.get("end", ""),
    }


def index(directory: str, force: bool = False) -> list[dict]:
    """Trip list with stats, cached on (size, mtime) so edits show up."""
    with _lock:
        out = []
        for path in trips_dir_files(directory):
            name = os.path.basename(path)
            st = os.stat(path)
            key = f"{st.st_size}:{st.st_mtime_ns}"
            hit = _index.get(name)
            if force or not hit or hit["key"] != key:
                _index[name] = {
                    "key": key,
                    "name": name,
                    "size": st.st_size,
                    "mtime": int(st.st_mtime),
                    **quick_stats(path),
                }
            out.append({k: v for k, v in _index[name].items() if k != "key"})
        return sorted(out, key=lambda t: t["mtime"])


def newest_trip(directory: str) -> str | None:
    files = trips_dir_files(directory)
    return os.path.basename(files[-1]) if files else None


def pull_from_phone(directory: str, device: str | None) -> dict:
    adb = adb_path()
    if not adb:
        return {"ok": False, "error": "adb not found (set ADB=/path/to/adb)"}
    dev = device or first_device(adb)
    if not dev:
        return {"ok": False, "error": "no phone attached (adb devices is empty)"}
    os.makedirs(directory, exist_ok=True)
    # Trailing '/.' copies the CONTENTS of the phone dir into our dir.
    cmd = [adb, "-s", dev, "pull", PHONE_TRIPS + "/.", directory]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    files = index(directory, force=True)
    return {
        "ok": res.returncode == 0,
        "device": dev,
        "output": (res.stdout + res.stderr).strip().splitlines()[-3:],
        "trips": len(files),
    }


def coverage_for_trip(directory: str, name: str) -> dict:
    """Fix-level coverage of the segment layer along one trip.

    Two different questions, and the app's log can only answer the second:
      * did the layer HAVE data under the car (a segment within 25 m)?
      * did the limit on screen come from it, from the motorbike statutory cap,
        or from the road-form guess?
    `_logFix` runs one line after the async layer lookup is kicked off, so the
    logged `limitLayer` lags a fix — compare the logged EFFECTIVE limit instead.
    """
    import waze_segments

    segs = segments_layer()
    path = os.path.join(directory, name)
    data = trip_view.load(path)
    fixes = _raw_fixes(path)
    out = {
        "fixes": 0, "layer_hit": 0, "layer_miss": 0,
        "app_exact": 0, "app_capped": 0, "app_guess": 0, "app_other": 0,
        "posted_extra": 0,
    }
    for f in fixes:
        lat = (f.get("latitudeE7") or 0) / 1e7
        lng = (f.get("longitudeE7") or 0) / 1e7
        if not lat:
            continue
        out["fixes"] += 1
        kmh, _st, _c, _dv, _d, _sid = segs.query(
            lat, lng, heading_deg=f.get("heading"), max_dist_m=25.0
        )
        if not kmh:
            out["layer_miss"] += 1
            continue
        out["layer_hit"] += 1
        app = f.get("limitEffective")
        if app is None:
            out["app_other"] += 1
            continue
        if kmh in (f.get("fwd"),):  # placeholder (property absent in fix logs)
            pass
        stat = _statutory_motorbike(f)
        if app == kmh:
            out["app_exact"] += 1
        elif app == min(stat, kmh) or app == stat:
            out["app_capped"] += 1
            if app < kmh:
                out["posted_extra"] += 1
        else:
            out["app_other"] += 1
    n = max(1, out["fixes"])
    hits = max(1, out["layer_hit"])
    out["pct_layer"] = round(100.0 * out["layer_hit"] / n)
    out["pct_exact"] = round(100.0 * out["app_exact"] / hits)
    out["pct_guess"] = round(100.0 * out["layer_miss"] / n)
    return out


def _raw_fixes(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return sorted(
            json.load(f).get("locations") or [],
            key=lambda x: int(x.get("timestampMs") or 0),
        )


# The app's motorbike class table (lib/services/overpass.dart), so "the app
# showed a lower number than the layer" can be told apart from "the app missed
# the layer": a posted value only TIGHTENS the vehicle's statutory limit.
_MB = {
    "motorway": 80, "motorway_link": 60, "trunk": 60, "trunk_link": 50,
    "primary": 60, "primary_link": 50, "secondary": 60, "secondary_link": 50,
    "tertiary": 60, "tertiary_link": 50, "unclassified": 50,
    "residential": 50, "living_street": 20, "service": 30,
    "pedestrian": 10, "footway": 10, "cycleway": 20,
}


def _statutory_motorbike(fix: dict) -> int:
    hw = fix.get("highway") or ""
    base = _MB.get(hw, 50)
    oneway = fix.get("oneway")
    lanes = fix.get("lanes")
    divided = bool(fix.get("divided"))
    urban = bool(fix.get("urban"))
    non_motor = (
        "motorway", "motorway_link", "living_street", "service",
        "pedestrian", "footway", "cycleway",
    )
    if (urban and hw not in non_motor) or hw in ("residential", "unclassified"):
        is_div = divided or (oneway is True and (lanes if lanes else 2) >= 2)
        return 60 if is_div else 50
    return base


def run_audit(directory: str) -> dict:
    script = os.path.join(REPO, "tool", "check_voice_calls.py")
    if not os.path.exists(script):
        return {"ok": False, "error": "tool/check_voice_calls.py not found"}
    try:
        res = subprocess.run(
            [sys.executable, script, directory],
            capture_output=True,
            text=True,
            timeout=900,
        )
    except Exception as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True, "text": (res.stdout + res.stderr).rstrip()}


def segments_layer():
    """Decode the WZSG layer once (1.03M segments, a few seconds)."""
    global _segs
    with _lock:
        if _segs is None:
            import waze_segments  # tool/waze_segments.py

            _segs = waze_segments.Segments(SEGMENTS_BIN)
        return _segs


def segments_geojson(bbox: tuple, cap: int = 2500) -> dict:
    """Segments overlapping [bbox] as GeoJSON, coloured by posted limit.

    A segment with fwd=rev=0 has NO posted data — the app falls back to the
    statutory road-form guess there, which is exactly what the map needs to show.
    """
    import waze_segments

    segs = segments_layer()
    min_lat, min_lng, max_lat, max_lng = bbox
    cell = waze_segments.CELL_DEG
    ids = set()
    for gy in range(int(min_lat // cell), int(max_lat // cell) + 1):
        for gx in range(int(min_lng // cell), int(max_lng // cell) + 1):
            ids.update(segs.grid.get((gy, gx), ()))

    features = []
    with_limit = named = 0
    for s in sorted(ids):
        pts = segs.pts[s]
        if not pts:
            continue
        if not (min_lat <= pts[0][0] <= max_lat and min_lng <= pts[0][1] <= max_lng):
            continue
        fwd, rev = segs.fwd[s], segs.rev[s]
        limit = max(fwd, rev) if (fwd or rev) else 0
        if limit:
            with_limit += 1
        name = segs.street(s)
        if name:
            named += 1
        # Decimate: the stored polylines are a few metres apart.
        step = max(1, len(pts) // 8)
        coords = [[round(p[1], 6), round(p[0], 6)] for p in pts[::step]]
        if len(coords) < 2:
            continue
        cls = segs.classes[s] if s < len(segs.classes) else 0
        features.append(
            {
                "type": "Feature",
                "geometry": {"type": "LineString", "coordinates": coords},
                "properties": {
                    "limit": limit,
                    "fwd": fwd,
                    "rev": rev,
                    "name": name,
                    "class": cls & 0x3F,
                    "split": bool(cls & 0x80),
                },
            }
        )
        if len(features) >= cap:
            break
    return {
        "type": "FeatureCollection",
        "features": features,
        "stats": {
            "in_bbox": len(ids),
            "shown": len(features),
            "with_limit": with_limit,
            "named": named,
            "cap": cap,
        },
    }


# The picker bar: a dropdown of trips + a pull button, injected into the
# viewer page so no page has to be generated ahead of time.
BAR = """
<style>
#nb-bar{position:fixed;top:8px;left:50%;transform:translateX(-50%);z-index:9999;
  display:flex;gap:8px;align-items:center;background:#111d;color:#eee;padding:6px 10px;
  border-radius:8px;font:12px/1.3 system-ui,sans-serif;backdrop-filter:blur(4px)}
#nb-bar select{max-width:380px;background:#222;color:#eee;border:1px solid #555;
  border-radius:4px;padding:3px 4px;font:12px system-ui,sans-serif}
#nb-bar button{background:#2d6cdf;color:#fff;border:0;border-radius:4px;padding:4px 8px;
  cursor:pointer;font:12px system-ui,sans-serif}
#nb-bar button:disabled{opacity:.55;cursor:default}
#nb-bar a{color:#9cf;text-decoration:none}
#nb-bar label{display:flex;gap:4px;align-items:center;cursor:pointer}
#nb-msg{max-width:320px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#nb-legend{position:fixed;left:8px;bottom:24px;z-index:9999;background:#111d;color:#eee;
  padding:6px 8px;border-radius:8px;font:11px/1.5 system-ui,sans-serif;display:none}
#nb-legend i{display:inline-block;width:14px;height:3px;margin-right:5px;
  vertical-align:middle}
</style>
<div id="nb-bar">
  <select id="nb-trips" title="recorded trips"></select>
  <button id="nb-pull" title="copy the trips off the phone with adb">Pull from phone</button>
  <label title="the Waze per-segment posted-limit layer the app looks up first">
    <input type="checkbox" id="nb-segs"> Waze segments
  </label>
  <a id="nb-json" href="#" title="raw trip JSON">json</a>
  <a id="nb-audit" href="/api/audit" target="_blank" title="run check_voice_calls.py">audit</a>
  <span id="nb-msg"></span>
</div>
<div id="nb-legend">
  <div><i style="background:#2ecc71"></i>≤ 40</div>
  <div><i style="background:#f1c40f"></i>50</div>
  <div><i style="background:#e67e22"></i>60</div>
  <div><i style="background:#e74c3c"></i>≥ 70</div>
  <div><i style="background:#aaa"></i>no posted data (app guesses)</div>
  <div id="nb-legend-count" style="margin-top:4px;opacity:.8"></div>
  <div id="nb-legend-cov" style="opacity:.8"></div>
</div>
<script>
const nbMsg = (t) => { document.getElementById('nb-msg').textContent = t || ''; };
const nbCurrent = __CURRENT__;
async function nbList() {
  const trips = await (await fetch('/api/trips')).json();
  const sel = document.getElementById('nb-trips');
  sel.innerHTML = '';
  for (const t of trips) {
    const o = document.createElement('option');
    o.value = t.name;
    const when = t.started ? t.started.slice(11, 16) + '→' + t.ended : '';
    o.textContent = `${t.name.replace('.json','')} · ${when} · ${t.km} km · `
      + `${t.fixes} fixes · ${t.maneuvers} maneuvers`;
    if (t.name === nbCurrent) o.selected = true;
    sel.appendChild(o);
  }
  document.getElementById('nb-json').href = '/api/trip/' + encodeURIComponent(nbCurrent);
  sel.onchange = () => { location.href = '/?trip=' + encodeURIComponent(sel.value); };
}
document.getElementById('nb-pull').onclick = async (e) => {
  e.target.disabled = true; nbMsg('pulling…');
  try {
    const r = await (await fetch('/api/pull', {method:'POST'})).json();
    nbMsg(r.ok ? `pulled ${r.trips} trips from ${r.device}` : 'pull failed: ' + r.error);
    if (r.ok) await nbList();
  } catch (err) { nbMsg('pull failed: ' + err); }
  e.target.disabled = false;
};

// ---- Waze segment layer overlay -----------------------------------------
// The app's primary posted-limit source, drawn under the trip path: the grey
// stretches are where it has NOTHING and falls back to the statutory guess.
map.createPane('nbSegs');
map.getPane('nbSegs').style.zIndex = 350;   // under the trip path (overlayPane)
map.getPane('nbSegs').style.opacity = 0.75;
let nbSegLayer = null;
const nbSegColor = (k) => k <= 0 ? '#aaaaaa' : k <= 40 ? '#2ecc71'
  : k <= 50 ? '#f1c40f' : k <= 60 ? '#e67e22' : '#e74c3c';
function nbBBox(pts, pad) {
  let a = [Infinity, Infinity, -Infinity, -Infinity];
  for (const p of pts) {
    a[0] = Math.min(a[0], p.lat); a[1] = Math.min(a[1], p.lng);
    a[2] = Math.max(a[2], p.lat); a[3] = Math.max(a[3], p.lng);
  }
  return [a[0] - pad, a[1] - pad, a[2] + pad, a[3] + pad].map(v => v.toFixed(5));
}
document.getElementById('nb-segs').onchange = async (e) => {
  if (!e.target.checked) {
    if (nbSegLayer) { map.removeLayer(nbSegLayer); nbSegLayer = null; }
    document.getElementById('nb-legend').style.display = 'none';
    return;
  }
  nbMsg('loading segment layer…');
  try {
    const bbox = nbBBox(DATA.path, 0.004).join(',');
    const geo = await (await fetch('/api/segments?bbox=' + bbox)).json();
    nbSegLayer = L.layerGroup();
    for (const f of geo.features) {
      const k = f.properties.limit;
      const line = L.polyline(f.geometry.coordinates.map(c => [c[1], c[0]]), {
        pane: 'nbSegs', color: nbSegColor(k),
        weight: k ? 3 : 2, opacity: k ? 0.9 : 0.6,
        dashArray: k ? null : '3,4',
      });
      line.bindPopup((f.properties.name || '(no name)') +
        (k ? ` · ${k} km/h` : ' · no posted limit') +
        (f.properties.fwd && f.properties.rev && f.properties.fwd !== f.properties.rev
          ? ` (${f.properties.fwd}/${f.properties.rev} per direction)` : '') +
        (f.properties.split ? ' · split carriageway' : ''));
      nbSegLayer.addLayer(line);
    }
    nbSegLayer.addTo(map);
    const st = geo.stats;
    document.getElementById('nb-legend').style.display = 'block';
    document.getElementById('nb-legend-count').textContent =
      `${st.with_limit} of ${st.shown} segments drawn here carry a posted limit`;
    nbMsg(`${st.shown} segments` + (st.in_bbox > st.shown
      ? ` (${st.in_bbox} in the box)` : ''));
    // Fix-level coverage: was there a segment under the car at all?
    try {
      const c = await (await fetch('/api/coverage?trip=' +
        encodeURIComponent(nbCurrent))).json();
      document.getElementById('nb-legend-cov').textContent =
        `${c.pct_layer}% of the drive had a segment within 25 m`;
      nbMsg(`${st.shown} segments · layer under the car ${c.pct_layer}% of fixes`);
    } catch (err) { /* coverage is a bonus, not required */ }
  } catch (err) { nbMsg('segment layer failed: ' + err); }
};
nbList().catch((e) => nbMsg('trip list failed: ' + e));
</script>
</body>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "NavBridgeTrips"
    directory = ""
    device: str | None = None

    def _send(self, body: bytes, ctype: str, code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200) -> None:
        self._send(
            json.dumps(obj, ensure_ascii=False).encode("utf-8"),
            "application/json; charset=utf-8",
            code,
        )

    def _html(self, html: str) -> None:
        self._send(html.encode("utf-8"), "text/html; charset=utf-8")

    def log_message(self, fmt: str, *args) -> None:  # keep the console quiet-ish
        if "/api/" in (self.path or ""):
            sys.stderr.write("  %s\n" % (fmt % args))

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        directory = self.directory

        if path in ("/", "/index.html"):
            want = (query.get("trip") or [""])[0]
            name = safe_name(want) if want else None
            if want and not name:
                return self._json({"error": f"bad trip name {want!r}"}, 400)
            if not name:
                latest = newest_trip(directory)
                if not latest:
                    return self._html(
                        "<p>No trips in "
                        f"<code>{directory}</code> — use the picker's "
                        "<b>Pull from phone</b> (<code>/api/pull</code>).</p>"
                    )
                name = latest
            full = os.path.join(directory, name)
            if not os.path.exists(full):
                return self._json({"error": f"{name} not found"}, 404)
            html = trip_view.build_html(trip_view.load(full))
            # Inject the picker just before </body> so it becomes a live app.
            html = html.replace(
                "</body>", BAR.replace("__CURRENT__", json.dumps(name)), 1
            )
            return self._html(html)

        if path == "/api/trips":
            return self._json(index(directory))

        if path.startswith("/api/trip/"):
            name = safe_name(path[len("/api/trip/"):])
            if not name:
                return self._json({"error": "bad trip name"}, 400)
            full = os.path.join(directory, name)
            if not os.path.exists(full):
                return self._json({"error": f"{name} not found"}, 404)
            with open(full, "rb") as f:
                return self._send(f.read(), "application/json; charset=utf-8")

        if path == "/api/audit":
            return self._json(run_audit(directory))

        if path == "/api/segments":
            raw = (query.get("bbox") or [""])[0]
            try:
                bbox = tuple(float(v) for v in raw.split(","))
                if len(bbox) != 4:
                    raise ValueError
            except ValueError:
                return self._json(
                    {"error": "bbox=minLat,minLng,maxLat,maxLng required"}, 400
                )
            return self._json(segments_geojson(bbox))

        if path == "/api/coverage":
            name = safe_name((query.get("trip") or [""])[0])
            if not name:
                return self._json({"error": "trip=<name> required"}, 400)
            if not os.path.exists(os.path.join(directory, name)):
                return self._json({"error": f"{name} not found"}, 404)
            return self._json(coverage_for_trip(directory, name))

        if path == "/api/pull":
            return self._json(pull_from_phone(directory, self.device))

        return self._json({"error": "not found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path == "/api/pull":
            return self._json(pull_from_phone(self.directory, self.device))
        return self._json({"error": "not found"}, 404)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--dir",
        default=os.path.join(REPO, "docs", "trips", "device"),
        help="trip directory (default: docs/trips/device)",
    )
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument(
        "--device",
        help="adb serial (default: ANDROID_SERIAL or the only attached device)",
    )
    ap.add_argument(
        "--no-pull", action="store_true", help="don't check adb on startup"
    )
    args = ap.parse_args()

    directory = os.path.abspath(args.dir)
    if not os.path.isdir(directory):
        print("no such trip dir:", directory)
        return 1
    Handler.directory = directory
    Handler.device = args.device or os.environ.get("ANDROID_SERIAL")

    trips = index(directory)
    adb = None if args.no_pull else adb_path()
    dev = None if args.no_pull else (Handler.device or (adb and first_device(adb)))

    httpd = None
    for port in range(args.port, args.port + 20):
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError as exc:
            print(f"  port {port} busy ({exc}); trying {port + 1}")
    if httpd is None:
        print("could not bind a port")
        return 1

    print("NavBridge trip server")
    print(f"  trips dir : {directory} ({len(trips)} trips)")
    print(
        "  phone     : "
        + (f"{dev} ({adb})" if dev else "none attached (Pull will report this)")
    )
    print(f"  viewer    : http://127.0.0.1:{httpd.server_port}/")
    print(
        f"  newest    : {trips[-1]['name']} — {trips[-1]['km']} km, "
        f"{trips[-1]['fixes']} fixes, {trips[-1]['maneuvers']} maneuvers"
        if trips
        else "  newest    : (none)"
    )
    print("  ctrl-c to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
