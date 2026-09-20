#!/usr/bin/env python3
"""Publish + serve monthly Waze-data update bundles for NavBridge.

The offline map assets (signs / cameras / speed-limits) live in
`assets/offline_map/`. This tool:

  * `--publish`  regenerates the Waze data (optional), copies the current
                 offline_map JSONs into a dated release dir, computes a SHA-256
                 per file, writes a `manifest.json`, and points `latest/` at it.
  * `--serve`    runs a small HTTP server that serves the release dir, so the
                 app can poll `GET /latest/manifest.json` and download changed
                 files.

Releases are immutable; `latest/` is a symlink to the newest date so clients
always fetch the current bundle.

The HTTP handler is rooted at `update/`, so the **actual** URL paths are
`/latest/...` and `/releases/<date>/...` (NOT `/update/...`).

Usage
-----
  # Regenerate Waze + VietMap data (crawl->decode->assets), then publish
  python3 tools/update_server.py --publish --rebuild

  # Same, but skip the VietMap KC01 download (Waze-only)
  python3 tools/update_server.py --publish --rebuild --no-vietmap

  # Publish using the already-built assets (no rebuild)
  python3 tools/update_server.py --publish

  # Serve the releases for the app/device
  python3 tools/update_server.py --serve --port 8080

`--rebuild` fetches the latest VietMap KC01 `edog_data.txt` (from
https://vietmap.vn/cap-nhat-ban-do-vietmap-kc01) and feeds it to
`tools/signs/build_vietmap.py`, in addition to the Waze crawl/rebuild.

The app polls:
  GET /latest/manifest.json
  GET /latest/<filename>
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent          # .../navbridge
ASSETS = REPO / "assets" / "offline_map"
RELEASES = REPO / "update" / "releases"
LATEST = REPO / "update" / "latest"

DECODE = Path("/Users/tungdl/Documents/Eink/Decode_Waze")
VIETMAP_DATA_DIR = REPO / "tools" / "data" / "vietmap_kc01"
STATE_FILE = REPO / "update" / ".vietmap_state.json"

# VietMap KC01 traffic-warning data (product update page). The download host is
# stable; the filename embeds the release tag (e.g. ...2026T9). We discover the
# current link by fetching the page and matching the first `.zip` href, so the
# filename does not need to be hardcoded.
VIETMAP_PAGE = "https://vietmap.vn/cap-nhat-ban-do-vietmap-kc01"

# Files we publish (the Waze-derived overlay data). Other offline assets (tiles,
# fonts, POIs) are not part of the monthly Waze refresh.
PUBLISH_FILES = [
    "vietnam_signs.json",
    "vietnam_cameras.json",
    "waze_speed_limits.json",
    "waze_segments.bin",
]

# Commands to regenerate each data artifact (run from their repo dirs).
# All can be skipped with --no-rebuild. VietMap EDOG runs after the Waze rebuild
# so it merges VietMap data on top (it never drops the Waze-crawled points).
REBUILD_STEPS = [
    ("waze-crawl", DECODE, [".venv/bin/python", "wme_crawl_http.py",
              "--bbox", "102.1,8.6,109.5,23.4", "--half", "0.05",
              "--workers", "8", "--out", "vn_features", "--resume"]),
    ("decode-mapcomments", DECODE, [".venv/bin/python", "extract_mapcomments.py"]),
    ("decode-hazards", DECODE, [".venv/bin/python", "extract_compare.py"]),
    ("build-mod-db", DECODE, [".venv/bin/python", "build_mod_db_v2.py"]),
    ("rebuild-waze-assets", REPO, ["python3", "tools/signs/rebuild_waze_assets.py"]),
    # The WME per-SEGMENT speed-limit asset (per-direction, ~95% of HCMC
    # segments). Runs straight off the crawl, so it must come after waze-crawl.
    ("build-waze-segments", REPO, ["python3", "tools/signs/build_waze_segments.py"]),
    ("dedup-cameras", REPO, ["python3", "tools/signs/dedup_cameras.py"]),
    ("build-vietmap", REPO, ["python3", "tools/signs/build_vietmap.py"]),
    ("dedup-signs", REPO, ["python3", "tools/signs/dedup_signs.py", "--write"]),
]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def find_first_zip_href(page: str) -> str:
    """Fetch a VietMap product page and return the first `.zip` download href."""
    try:
        with urllib.request.urlopen(page, timeout=30) as r:
            html = r.read().decode("utf-8", "replace")
    except Exception as e:
        print(f"[vietmap] page fetch failed: {e}", file=sys.stderr)
        return ""

    # Lowercase the html for a case-insensitive scan, but keep a parallel map of
    # the original hrefs. Simple regex: href="...zip".
    import re
    for m in re.finditer(r'href=["\']([^"\']+\.zip)["\']', html, re.I):
        url = m.group(1)
        if url.startswith("//"):
            url = "https:" + url
        elif url.startswith("/"):
            url = "https://vietmap.vn" + url
        return url
    # fallback: known stable host pattern
    return "https://download.vietmap.vn/dvr/VietMap_KC01_G40_TS-2K_2026T9.zip"


def load_vietmap_state() -> dict:
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"[vietmap] warning: error reading state: {e}", file=sys.stderr)
    return {}


def save_vietmap_state(state: dict):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def download_vietmap(dest_dir: Path = VIETMAP_DATA_DIR) -> Path:
    """Download the latest VietMap KC01 zip and extract edog_data.txt.

    Returns the path to the extracted edog_data.txt, or empty Path if it could not be
    obtained (the caller continues; VietMap is an optional enhancement).
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    url = find_first_zip_href(VIETMAP_PAGE)
    if not url:
        print("[vietmap] no zip URL found; skipping VietMap data", file=sys.stderr)
        return Path("")
    print(f"[vietmap] downloading {url}")
    # Download the zip to a temp path (NOT under dest_dir, which we clear below).
    tmpdir = Path(tempfile.mkdtemp())
    zpath = tmpdir / "vietmap_kc01.zip"
    try:
        urllib.request.urlretrieve(url, zpath)
    except Exception as e:
        print(f"[vietmap] download failed: {e}", file=sys.stderr)
        shutil.rmtree(tmpdir, ignore_errors=True)
        return Path("")
    # Remove the old extracted dir, then extract into dest_dir so the resulting
    # edog_data.txt sits at dest_dir/edog_data.txt (no nested double folder).
    if dest_dir.exists():
        shutil.rmtree(dest_dir, ignore_errors=True)
    dest_dir.mkdir(parents=True, exist_ok=True)
    edog_found = None
    with zipfile.ZipFile(zpath) as zf:
        for n in zf.namelist():
            if n.endswith("edog_data.txt"):
                zf.extract(n, dest_dir)
                # copy it up to dest_dir/edog_data.txt so the newest-edog
                # discovery (build_vietmap.py) finds it at a stable path
                extracted = dest_dir / Path(n)
                edog_found = dest_dir / "edog_data.txt"
                shutil.copy2(extracted, edog_found)
                break
    shutil.rmtree(tmpdir, ignore_errors=True)
    if edog_found is None or not edog_found.exists():
        print("[vietmap] edog_data.txt not found in zip", file=sys.stderr)
        return Path("")
    print(f"[vietmap] extracted {edog_found} ({edog_found.stat().st_size} bytes)")
    return edog_found


def run_vietmap_pipeline(force: bool = False, check_only: bool = False) -> bool:
    """Run headless VietMap KC01 download, merge, dedup, and publish.

    Idempotent: if the current VietMap release URL has already been processed and
    latest/ manifest exists, it exits cleanly (0) unless --force is given.
    """
    url = find_first_zip_href(VIETMAP_PAGE)
    state = load_vietmap_state()
    last_url = state.get("last_url", "")
    last_pub = state.get("last_published", "")

    if check_only:
        print(f"[vietmap] Available upstream URL: {url}")
        print(f"[vietmap] Last processed URL:     {last_url or '(none)'}")
        print(f"[vietmap] Last published date:    {last_pub or '(none)'}")
        is_new = bool(url and url != last_url)
        print(f"[vietmap] New update available:   {'YES' if is_new else 'NO'}")
        return True

    latest_manifest = LATEST / "manifest.json"
    if not force and url and url == last_url and latest_manifest.exists():
        print(f"[vietmap] Up to date with latest release: {url}")
        print(f"[vietmap] (Last published: {last_pub}). Use --force to rebuild.")
        return True

    print(f"[vietmap] Starting VietMap update pipeline (URL: {url})...")
    edog = download_vietmap(VIETMAP_DATA_DIR)
    if not edog or not edog.exists():
        print("[vietmap] ERROR: Failed to obtain edog_data.txt", file=sys.stderr)
        sys.exit(1)

    steps = [
        ("build-vietmap", REPO, ["python3", "tools/signs/build_vietmap.py", str(edog)]),
        ("dedup-cameras", REPO, ["python3", "tools/signs/dedup_cameras.py"]),
        ("dedup-signs", REPO, ["python3", "tools/signs/dedup_signs.py", "--write"]),
    ]
    for label, cwd, cmd in steps:
        print(f"[vietmap] {label}: {' '.join(cmd)}")
        r = subprocess.run(cmd, cwd=str(cwd))
        if r.returncode != 0:
            print(f"[vietmap] FAILED step {label} (exit code {r.returncode})", file=sys.stderr)
            sys.exit(r.returncode)

    publish()

    # Save state
    state["last_url"] = url
    state["last_published"] = time.strftime("%Y-%m-%d")
    state["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%S+07:00")
    state["edog_file"] = str(edog)
    state["edog_bytes"] = edog.stat().st_size
    save_vietmap_state(state)
    print(f"[vietmap] Update pipeline completed successfully for {url}")
    return True


def run_steps(no_vietmap: bool = False):
    if not no_vietmap:
        download_vietmap(VIETMAP_DATA_DIR)
        if DECODE.exists():
            dest = DECODE / "vietmap_kc01"
            dest.mkdir(parents=True, exist_ok=True)
            if (VIETMAP_DATA_DIR / "edog_data.txt").exists():
                shutil.copy2(VIETMAP_DATA_DIR / "edog_data.txt", dest / "edog_data.txt")
    for label, cwd, cmd in REBUILD_STEPS:
        print(f"[rebuild] {label}: cd {cwd} && {' '.join(cmd)}")
        r = subprocess.run(cmd, cwd=str(cwd))
        if r.returncode != 0:
            print(f"[rebuild] FAILED: {label}: {' '.join(cmd)} (exit {r.returncode})",
                  file=sys.stderr)
            sys.exit(1)


def publish():
    date = time.strftime("%Y-%m-%d")
    release = RELEASES / date
    release.mkdir(parents=True, exist_ok=True)

    files = {}
    for name in PUBLISH_FILES:
        src = ASSETS / name
        if not src.exists():
            print(f"[publish] MISSING asset: {src}", file=sys.stderr)
            sys.exit(1)
        dst = release / name
        shutil.copy2(src, dst)
        files[name] = {
            "sha256": sha256(dst),
            "size": dst.stat().st_size,
        }

    gen = time.strftime("%Y-%m-%dT%H:%M:%S+07:00")
    manifest = {
        "version": date,
        "generated": gen,
        "files": files,
    }
    with open(release / "manifest.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    version_data = {
        "cameras": files.get("vietnam_cameras.json", {}).get("sha256", "")[:16],
        "signs": files.get("vietnam_signs.json", {}).get("sha256", "")[:16],
        "speed_limits": files.get("waze_speed_limits.json", {}).get("sha256", "")[:16],
    }
    with open(release / "version.json", "w", encoding="utf-8") as f:
        json.dump(version_data, f, ensure_ascii=False, indent=2)

    # Point latest/ at the newest release.
    if LATEST.exists() or LATEST.is_symlink():
        if LATEST.is_symlink():
            LATEST.unlink()
        else:
            shutil.rmtree(LATEST)
    LATEST.symlink_to(RELEASES / date, target_is_directory=True)

    print(f"[publish] {date} -> {release}")
    print(f"[publish] latest -> {'/update/releases/' + date}")
    for name, meta in files.items():
        print(f"  {name:26} {meta['size']:>10} bytes  sha256={meta['sha256'][:12]}…")


class Handler(SimpleHTTPRequestHandler):
    """Serve the update dir; default index lists releases."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(REPO / "update"), **kwargs)

    def end_headers(self):
        # Allow cross-origin so the Flutter app can fetch over HTTP.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass  # quiet


def serve(port: int):
    os.chdir(REPO / "update")
    handler = lambda *a, **k: Handler(*a, **k)
    httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    print(f"[serve] http://0.0.0.0:{port}/latest/manifest.json")
    print("        press Ctrl-C to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[serve] stopped")
        httpd.server_close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--publish", action="store_true", help="build + publish a release")
    ap.add_argument("--rebuild", action="store_true",
                    help="with --publish: run the full crawl+decode+asset rebuild")
    ap.add_argument("--no-vietmap", action="store_true",
                    help="with --rebuild: skip the VietMap KC01 download")
    ap.add_argument("--vietmap-only", action="store_true",
                    help="run VietMap KC01 download + merge + dedup + publish")
    ap.add_argument("--check-only", action="store_true",
                    help="check upstream VietMap release URL against last processed state")
    ap.add_argument("--force", action="store_true",
                    help="force rebuild even if VietMap URL was already processed")
    ap.add_argument("--serve", action="store_true", help="serve the releases over HTTP")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    if args.check_only:
        run_vietmap_pipeline(check_only=True)
    elif args.vietmap_only:
        run_vietmap_pipeline(force=args.force)
    elif args.publish:
        if args.rebuild:
            run_steps(no_vietmap=args.no_vietmap)
        publish()
    elif args.serve:
        serve(args.port)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
