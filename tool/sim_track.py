#!/usr/bin/env python3
"""Run the ALGORITHM over a route: GPS points in, a TRIP out.

This is the simulation rig, and it is deliberately not the replay:

  * **Playback** (`?trip=…`) drives a RECORDED drive and is handed that
    recording's own answers — the route is the recorded track and every fix's
    road identity is injected from the file (`_applyReplayRoad`). It can never
    test the road chain, because it feeds the app's own past output back in.
  * **Simulation** (this script) is given only a route. The app plans it with
    its real router, samples the GPS stream ALONG that planned geometry (so the
    points are on the route by construction, and the app never thinks it is
    off-route and reroutes), adds the receiver's error structure, and lets the
    road chain decide everything. The output is the TRIP document itself —
    the same `toTakeoutJson()` a finished drive writes, i.e. the shape of
    `docs/trips/device/*.json`, so every existing audit tool reads it unchanged.

The app runs in a real build (a Flutter web release bundle in headless Chrome),
so nothing about the pipeline is stubbed: outlier gate, heading filter, road
lookup, posted-limit layer, sign adoption, built-up verdict, voice queue and the
trip logger all run as they do on the phone.

    # endpoints straight from the shell
    python3 tool/sim_track.py --from 10.8000,106.6400 --to 11.9400,108.4400

    # …or taken from a track fixture (its own points are NOT driven)
    python3 tool/sim_track.py --track docs/trips/device/2026-10-08_174056*.json

    # a bad receiver, and a repeatable one
    python3 tool/sim_track.py --from ... --to ... --noise 2.0 --seed 11

Anything else it needs is derived: the budget from the route the app reports, the
speed from --tspeed, and the trip's path from --out.
"""
from __future__ import annotations

import argparse
import glob
import http.server
import json
import os
import pathlib
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / 'build' / 'web'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
OSRM = 'https://router.project-osrm.org'

# path -> (body, content-type, status): one plan per distinct request per run.
_ROUTE_CACHE: dict[str, tuple[bytes, str, int]] = {}

# ⭐ WHAT THIS SCRIPT DOES NOT DO: plan the route.
#
# It used to. The tool called OSRM, decoded the polyline HERE, and handed the app
# an already-decoded point list (`geometry_points`) — because the public server
# sends no CORS headers, so a BROWSER fetch to it is blocked and the app could not
# plan anything at all on web.
#
# That made the rig test the wrong program. The route is the app's own work: the
# request, the polyline decode, the manoeuvres, the step distances. A route decoded
# by the driver's Python is one the app merely obeys, and a decoder bug inside the
# app (there was one — `_geometryOf`/`decodePolyline` in osrm.dart) is exactly
# what such a rig cannot see. The fix is the same-origin relay in `_Sink`: with it
# the app plans and decodes its own route, and this script is reduced to a file
# server, a relay, and a place for the finished trip to land.


def _straight_km(frm: str, to: str) -> float:
    """Rough distance, km — a BUDGET estimate, nothing more.

    The real distance is the route the APP plans and is not known until the run has
    started. Roads are longer than the straight line (measured: 2.74 km driven for
    1.55 km of straight line on the test route), hence the factor; the driver stops
    the moment the trip arrives, so an over-estimate costs nothing.
    """
    import math
    fa = [float(x) for x in frm.split(',')]
    ta = [float(x) for x in to.split(',')]
    return math.hypot((ta[0] - fa[0]) * 111.0, (ta[1] - fa[1]) * 109.0) * 1.4



class _Sink(http.server.SimpleHTTPRequestHandler):
    """Static files + two sinks: the app's log, and the finished TRIP."""

    trip_body: list[bytes] = []
    log_lines: list[str] = []

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WEB), **kw)

    def log_message(self, *a):  # keep the console readable
        pass

    def handle_one_request(self):  # noqa: N802
        # The browser abandons a request whose answer took 76 s (it has its own
        # timeout) and the relay then writes into a closed socket. That is a
        # slow upstream, not a bug here, and a stack trace per abandoned request
        # buries the log the run is actually read through.
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_GET(self):  # noqa: N802
        if self.path.startswith('/osrm/'):
            self._relay_osrm()
        else:
            super().do_GET()

    def _relay_osrm(self) -> None:
        """Forward `/osrm/...` to the public server, unchanged.

        ⭐ A RELAY, not a proxy with opinions: the body travels byte for byte, so
        the app parses and decodes exactly what OSRM sent. The only thing added
        is the same-origin address that makes the browser willing to fetch it.

        Answers are CACHED for the life of the run. The public server is slow and
        variable (measured 76 s for a 2.7 km route, then a timeout on a 20 s
        client budget), and a second simulation of the same pair is usually being
        run to compare a fix against the first — which should not cost another
        round trip to a stranger's server.
        """
        import urllib.error
        import urllib.request
        if self.path in _ROUTE_CACHE:
            body, ctype, code = _ROUTE_CACHE[self.path]
            print(f'  relay: {self.path} -> {code} ({len(body)} bytes, cached)')
        else:
            url = OSRM + self.path[len('/osrm'):]
            t = time.time()
            try:
                with urllib.request.urlopen(url, timeout=120) as r:
                    body = r.read()
                    ctype = r.headers.get('Content-Type', 'application/json')
                    code = r.status
            except urllib.error.HTTPError as e:
                body, ctype, code = e.read(), 'application/json', e.code
            except Exception as e:  # noqa: BLE001 — surfaced to the app as JSON
                body = json.dumps({'code': 'RelayError', 'message': str(e)}).encode()
                ctype, code = 'application/json', 502
            print(f'  relay: {self.path} -> {code} ({len(body)} bytes) in '
                  f'{time.time() - t:.1f}s')
            if code == 200:
                _ROUTE_CACHE[self.path] = (body, ctype, code)
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else b''
        if self.path.startswith('/__trip'):
            type(self).trip_body.append(body)
        elif self.path.startswith('/__log'):
            type(self).log_lines.extend(body.decode('utf-8', 'replace').splitlines())
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        # The trip fixture and the app bundle are regenerated between runs; a
        # cached copy would silently simulate the PREVIOUS build.
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


def read_track_endpoints(path_or_url: str) -> tuple[str, str, float]:
    """(from, to, km) from a track fixture — the points themselves are ignored."""
    if path_or_url.startswith('http'):
        import urllib.request
        raw = urllib.request.urlopen(path_or_url, timeout=20).read().decode('utf-8')
        doc = json.loads(raw)
    else:
        matches = glob.glob(path_or_url)
        if not matches:
            raise SystemExit(f'no such track: {path_or_url}')
        doc = json.loads(pathlib.Path(matches[0]).read_text(encoding='utf-8'))
    locs = doc.get('locations') if isinstance(doc, dict) else doc
    if not isinstance(locs, list) or len(locs) < 2:
        raise SystemExit(f'{path_or_url}: no locations[] to take endpoints from')

    def ll(e):
        lat = e.get('latitudeE7', e.get('latitude'))
        lng = e.get('longitudeE7', e.get('longitude'))
        return (lat / 1e7 if e.get('latitudeE7') is not None else lat,
                lng / 1e7 if e.get('longitudeE7') is not None else lng)

    a, b = ll(locs[0]), ll(locs[-1])
    km = 0.0
    prev = None
    import math
    for e in locs:
        p = ll(e)
        if prev is not None:
            dy = (p[0] - prev[0]) * 111000.0
            dx = (p[1] - prev[1]) * 109000.0
            km += math.hypot(dy, dx) / 1000.0
        prev = p
    return f'{a[0]:.6f},{a[1]:.6f}', f'{b[0]:.6f},{b[1]:.6f}', km


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='frm', help='lat,lng of the start')
    ap.add_argument('--to', help='lat,lng of the destination')
    ap.add_argument('--track', help='take the endpoints from this track fixture')
    ap.add_argument('--gps', default=None,
                    help='drive THIS GPS trace (served path or URL) and nothing '
                         'else: no route is planned, so every road, limit, sign '
                         'and announcement has to come out of the map data. This '
                         'is the raw-input mode; --from/--to hand the app a route '
                         'it merely follows.')
    ap.add_argument('--pace', type=float, default=13.9,
                    help='ground speed m/s (default 13.9 = 50 km/h)')
    ap.add_argument('--noise', type=float, default=1.0,
                    help='receiver error multiplier; 0 = a perfect trace')
    ap.add_argument('--seed', type=int, default=7, help='repeatable noise')
    ap.add_argument('--tspeed', type=float, default=8.0,
                    help='how fast to FEED the drive (wall-clock multiplier)')
    ap.add_argument('--vehicle', choices=['motorbike', 'car', 'truck'],
                    default=None, help='override the vehicle class')
    ap.add_argument('--nav', action='store_true',
                    help='with --gps: also plan a route from the trace to its '
                         'own last point, the way a real drive has one (the '
                         'driver picked a destination) — this is what makes '
                         'turn/next-street callouts possible')
    ap.add_argument('--out', default=None,
                    help='where to write the trip (default docs/trips/sim/<stamp>.json)')
    ap.add_argument('--port', type=int, default=8110)
    ap.add_argument('--km', type=float, default=0.0,
                    help='known route length, km — otherwise estimated from the '
                         'straight line, because the app plans the real one')
    ap.add_argument('--slack', type=float, default=150.0,
                    help='extra wall-clock seconds on top of the drive time '
                         '(must cover the app\'s own OSRM plan: ~76 s measured)')
    ap.add_argument('--dry-run', action='store_true',
                    help='print the URL and budget, do not launch Chrome')
    a = ap.parse_args()

    mode = 'gps' if a.gps else 'route'
    km = 0.0
    if a.gps:
        print(f'GPS trace mode: driving {a.gps} — NO route will be planned')
    elif a.track:
        frm, to, km = read_track_endpoints(a.track)
        print(f'endpoints from {a.track}: {frm} -> {to}  ({km:.1f} km of track)')
    elif a.frm and a.to:
        frm, to, km = a.frm, a.to, 0.0
    else:
        raise SystemExit('need --gps, --track, or --from and --to')

    if not WEB.is_dir():
        raise SystemExit(f'{WEB} is missing — run: flutter build web')

    # ── budget: the app plans the route itself (through the relay below), then
    # synthesises the drive on the drive's own clock and feeds it at --tspeed, so
    # the wall-clock cost is that plan plus drive_time / tspeed. The plan is one
    # OSRM round trip and the public server is SLOW (measured: 76 s for a 2.7 km
    # route), which is why --slack defaults high. The driver also stops the
    # moment the trip arrives.
    km_est = a.km or (_straight_km(frm, to) if mode == 'route' else 0.0)
    drive_s = km_est * 1000.0 / a.pace
    budget = drive_s / max(a.tspeed, 0.1) + a.slack
    if mode == 'gps':
        # In GPS mode the app plans nothing, so the wall clock is just the feed
        # plus the per-fix work — there is no slow OSRM round trip to wait for.
        print(f'budget {budget:.0f}s wall clock (feed + per-fix work; no plan '
              'to wait for)' if not a.km else
              f'{km_est:.1f} km of trace at {a.pace * 3.6:.0f} km/h -> '
              f'{drive_s / 60:.1f} min of drive time, fed at {a.tspeed}× -> '
              f'budget {budget:.0f}s wall clock')
    else:
        print(f'{km_est:.1f} km (est) at {a.pace * 3.6:.0f} km/h -> '
              f'{drive_s / 60:.1f} min of drive time, fed at {a.tspeed}× -> '
              f'budget {budget:.0f}s wall clock'
              + ('' if a.km else ' (straight-line estimate; the app plans the real one)'))

    if mode == 'gps':
        url = (f'http://127.0.0.1:{a.port}/logged.html'
               f'?gps={a.gps}'
               f'&tspeed={a.tspeed:g}'
               + ('&nav=1' if a.nav else ''))
    else:
        url = (f'http://127.0.0.1:{a.port}/logged.html'
               f'?sim={frm},{to}'
               f'&osrm=/osrm'
               f'&pace={a.pace:g}&noise={a.noise:g}&seed={a.seed}&tspeed={a.tspeed:g}')
    if a.vehicle:
        url += f'&vehicle={a.vehicle}'
    print(f'URL {url}')
    if a.dry_run:
        return 0

    out = pathlib.Path(a.out) if a.out else (
        ROOT / 'docs' / 'trips' / 'sim' /
        time.strftime('%Y-%m-%d_%H%M%S_sim.json'))
    out.parent.mkdir(parents=True, exist_ok=True)

    _Sink.trip_body = []
    _Sink.log_lines = []
    socketserver.TCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer(('127.0.0.1', a.port), _Sink)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f'serving {WEB} on {a.port} (/__log, /__trip)')

    # ⭐ ONE Chrome profile PER RUN. A shared default profile is single-instance:
    # a new run hands the URL to a Chrome that is still exiting and loads
    # NOTHING, which looks exactly like the app being silent (9 of 22 runs died
    # that way once — see navbridge-emulator-sim).
    profile = tempfile.mkdtemp(prefix='nbsim-')
    cmd = [CHROME, '--headless=new', '--enable-unsafe-swiftshader',
           f'--user-data-dir={profile}', '--no-first-run',
           '--no-default-browser-check', '--enable-logging=stderr', '-v=0',
           url]
    started = time.time()
    # ⭐ Chrome's OWN stderr is the reliable channel: the page's /__log sink has
    # been intermittent (0 lines on some runs), while `--enable-logging=stderr`
    # printed the whole app console every time (that is how a bogus decoded
    # destination was found). Capture both; the macOS CVDisplayLink noise is
    # filtered out when the log is read.
    err_path = out.with_suffix('.chrome.log')
    err_file = open(err_path, 'w')
    proc = subprocess.Popen(cmd, stdout=err_file, stderr=err_file)
    print('waiting for the trip…')
    trip = None
    try:
        while time.time() - started < budget:
            if _Sink.trip_body:
                trip = _Sink.trip_body[-1]
                break
            time.sleep(1.0)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
        err_file.close()
        shutil.rmtree(profile, ignore_errors=True)
        srv.shutdown()

    wall = time.time() - started
    # Merge both channels, keeping drive order by the page's +Nms stamps where
    # present. Chrome prefixes its console lines with INFO:CONSOLE:<line>.
    sink = _Sink.log_lines
    raw = err_path.read_text(encoding='utf-8', errors='replace')
    console = []
    for line in raw.splitlines():
        if 'cv_display_link' in line or 'CVDisplayLink' in line:
            continue
        m = re.search(r'INFO:CONSOLE:\d+\] "(.*)", source:', line)
        if m:
            console.append(m.group(1))
            continue
        if 'INFO:CONSOLE' in line:
            console.append(line.split('INFO:CONSOLE', 1)[1].strip())
    log = '\n'.join(sink) + ('\n' if sink and console else '') + '\n'.join(console)
    out.with_suffix('.log').write_text(log, encoding='utf-8')

    print(f'\n=== the app\'s own log: {out.with_suffix(".log")} ===')
    for pat in (r'SIM: from', r'SIM: route planned', r'SIM: \d+ synthesised',
                r'SIM: navigation STARTED', r'SIM: drive finished',
                r'SIM: trip POSTed', r'SIM: TRIP', r'SIM: could not',
                r'PAGE-ERROR|Uncaught'):
        for line in log.splitlines():
            if re.search(pat, line):
                print('  ' + line.strip()[:160])
                break

    if not trip:
        print(f'\nNO TRIP after {wall:.0f}s — the app never finished the drive.')
        print('See the log above (a routing failure and a rejected track both '
              'stop the run before a trip exists).')
        return 1

    body = trip.decode('utf-8', 'replace')
    out.write_text(body, encoding='utf-8')
    doc = json.loads(body)
    locs = doc.get('locations', [])
    anns = doc.get('announcements', [])
    kinds: dict[str, int] = {}
    for an in anns:
        kinds[an.get('kind', '?')] = kinds.get(an.get('kind', '?'), 0) + 1
    limits = sorted({l.get('limitEffective') for l in locs
                     if l.get('limitEffective')}, key=lambda v: (v is None, v))
    print(f'\n=== TRIP {out} ({len(body)} bytes) ===')
    print(f'  {len(locs)} fixes, {len(anns)} announcements, '
          f'limits seen {limits}')
    print(f'  kinds {kinds}')
    print(f'  wall clock {wall:.0f}s')
    print('\nAudit it with the usual tools, e.g.:')
    print(f'  python3 tool/announce_speed_audit.py {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
