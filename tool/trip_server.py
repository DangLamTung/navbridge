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

_lock = threading.Lock()
_index: dict[str, dict] = {}  # name -> {size, mtime, stats...}


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
#nb-msg{max-width:320px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
</style>
<div id="nb-bar">
  <select id="nb-trips" title="recorded trips"></select>
  <button id="nb-pull" title="copy the trips off the phone with adb">Pull from phone</button>
  <a id="nb-json" href="#" title="raw trip JSON">json</a>
  <a id="nb-audit" href="/api/audit" target="_blank" title="run check_voice_calls.py">audit</a>
  <span id="nb-msg"></span>
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
