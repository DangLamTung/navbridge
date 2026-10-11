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
import gzip
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
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
WME_COOKIE_FILE = REPO / "tools" / "data" / "wme_cookie.txt"

CRAWL_STATUS = {
    "status": "idle",  # "idle" | "running" | "completed" | "failed"
    "progress": "Sẵn sàng",
    "started_at": "",
    "finished_at": "",
    "error": "",
}


def check_wme_session(cookie: str = "") -> bool:
    """Check if WME session is active and can fetch segment data."""
    if not cookie:
        cookie = os.environ.get("WME_COOKIE", "")
        if not cookie and WME_COOKIE_FILE.exists():
            cookie = WME_COOKIE_FILE.read_text(encoding="utf-8").strip()
    if not cookie:
        return False

    test_url = "https://www.waze.com/row-Descartes/app/Features?bbox=106.69,10.77,106.71,10.79"
    req = urllib.request.Request(
        test_url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
            "Cookie": cookie,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = resp.read()
            if b"login" in resp.url.lower().encode() or resp.status in (401, 403):
                return False
            return len(data) > 100
    except Exception:
        return False


def start_crawl_pipeline_background(cookie: str = ""):
    """Run full crawl + rebuild + publish in background thread upon valid cookie."""
    if cookie:
        os.environ["WME_COOKIE"] = cookie
        WME_COOKIE_FILE.parent.mkdir(parents=True, exist_ok=True)
        WME_COOKIE_FILE.write_text(cookie, encoding="utf-8")

    def run():
        global CRAWL_STATUS
        CRAWL_STATUS["status"] = "running"
        CRAWL_STATUS["started_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        CRAWL_STATUS["progress"] = "Đang bắt đầu pipeline cào dữ liệu và tổng hợp các nguồn..."
        CRAWL_STATUS["error"] = ""
        try:
            print("\n[WME Crawl Trigger] Starting automated update pipeline...")
            # 1. Run all sources pipeline
            CRAWL_STATUS["progress"] = "Đang chạy auto_update pipeline (KC01 + WME + deduplication)..."
            cmd = ["bash", "tools/auto_update.sh", "--force"]
            p = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True)
            if p.returncode != 0:
                print(f"[crawl worker] Warning: {p.stderr}", file=sys.stderr)

            # 2. Publish release bundle & version.json
            CRAWL_STATUS["progress"] = "Đang xuất bản version.json và manifest.json mới..."
            publish(force=True)

            CRAWL_STATUS["status"] = "completed"
            CRAWL_STATUS["finished_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
            CRAWL_STATUS["progress"] = "Thành công! Đã phát hành dữ liệu mới. App NavBridge sẽ tự động cập nhật."
            print(f"[WME Crawl Trigger] {CRAWL_STATUS['progress']}")
        except Exception as e:
            CRAWL_STATUS["status"] = "failed"
            CRAWL_STATUS["error"] = str(e)
            CRAWL_STATUS["progress"] = f"Lỗi: {e}"
            print(f"[WME Crawl Trigger] Failed: {e}", file=sys.stderr)

    threading.Thread(target=run, daemon=True).start()


# Where `--publish` copies the bundles once they are built (see `upload`).
# Empty = publish only into `update/` locally. Overridable with `--upload TARGET`.
UPLOAD_TARGET = os.environ.get("UPLOAD_TARGET", "")

# VietMap KC01 traffic-warning data (product update page). The download host is
# stable; the filename embeds the release tag (e.g. ...2026T9). We discover the
# current link by fetching the page and matching the first `.zip` href, so the
# filename does not need to be hardcoded.
VIETMAP_PAGE = "https://vietmap.vn/cap-nhat-ban-do-vietmap-kc01"

# Files we publish — EVERYTHING the app can load from the update server, so a
# data fix no longer needs a new APK. `waze_segments.bin` is listed for
# completeness, but the client deliberately does not background-download it
# (28 MB); its loader simply prefers it when it is already on the device.
PUBLISH_FILES = [
    "vietnam_signs.json",
    "vietnam_cameras.json",
    "waze_speed_limits.json",
    "vietmap_speed_limits.json",
    "vietnam_pois.json",
    "vietnam_places.json",
    "nav_style.json",
    "overview_tiles.tar.gz",
    "waze_segments.bin",
]

# --- pre-publish sanity gate -------------------------------------------------
# A crawl cut short by an expired Waze session silently produces a tiny tile
# set, and a bad decode produces a nearly empty segment layer. Either would be
# published as `latest/` and pushed to every device, so refuse to publish unless
# the numbers look like a real nationwide build (override with --force).
MIN_TILES = 10_000
MIN_SEGS = 1_000_000
MIN_STREETS = 20_000
MIN_FILE_BYTES = {
    "vietnam_signs.json": 100_000,
    "vietnam_cameras.json": 100_000,
    "waze_speed_limits.json": 10_000,
    "vietmap_speed_limits.json": 10_000,
    "vietnam_pois.json": 100_000,
    # The place index is deliberately small (a few thousand rows).
    "vietnam_places.json": 1_000,
    "nav_style.json": 1_000,
    "overview_tiles.tar.gz": 100_000,
    "waze_segments.bin": 10 << 20,
}


def read_segments_header(path: Path) -> dict:
    """Parse the 40-byte WZSG header written by tools/signs/build_waze_segments.py.

    The field order is the contract with lib/services/offline_speed_limits.dart.
    These are the numbers a truncated or broken build shows up in first.
    """
    try:
        with open(path, "rb") as f:
            raw = f.read(40)
    except OSError:
        return {}
    if len(raw) < 40:
        return {}
    (magic, ver, n_pts, n_coord_b, n_segs, cell_e4, n_streets,
     _lat0, _lng0, blob_b) = struct.unpack_from("<4sIIIIIIiiI", raw, 0)
    if magic != b"WZSG":
        return {}
    return {
        "version": ver,
        "nPoints": n_pts,
        "nCoordBytes": n_coord_b,
        "nSegs": n_segs,
        "cellE4": cell_e4,
        "nStreets": n_streets,
        "streetBlobBytes": blob_b,
    }


def validate_assets(force: bool = False) -> bool:
    """Refuse to publish a build whose counts collapsed (see MIN_* above)."""
    problems = []

    crawl = DECODE / "vn_features"
    if crawl.exists():
        n = len(list(crawl.glob("*.json")))
        if n < MIN_TILES:
            problems.append(
                f"crawl tiles: {n:,} < {MIN_TILES:,} — interrupted crawl "
                f"(expired Waze session?) in {crawl}")
    else:
        print(f"[validate] no crawl dir at {crawl} — tile-count check skipped")

    segs = read_segments_header(ASSETS / "waze_segments.bin")
    if not segs:
        problems.append("waze_segments.bin: missing or bad WZSG header")
    else:
        if segs["nSegs"] < MIN_SEGS:
            problems.append(
                f"waze_segments.bin: nSegs={segs['nSegs']:,} < {MIN_SEGS:,}")
        if segs["nStreets"] < MIN_STREETS:
            problems.append(
                f"waze_segments.bin: nStreets={segs['nStreets']:,} "
                f"< {MIN_STREETS:,}")

    for name, floor in MIN_FILE_BYTES.items():
        p = ASSETS / name
        if not p.exists():
            problems.append(f"{name}: missing")
        elif p.stat().st_size < floor:
            problems.append(f"{name}: {p.stat().st_size:,} B < {floor:,} B")

    if problems:
        print("\n[validate] PUBLISH BLOCKED — the counts look like a broken build:")
        for pr in problems:
            print(f"  x {pr}")
        if force:
            print("[validate] --force given: publishing anyway.")
            return False
        sys.exit(1)

    if segs:
        print(f"[validate] OK — nSegs={segs['nSegs']:,} "
              f"nStreets={segs['nStreets']:,} nPoints={segs['nPoints']:,}")
    return True

# Commands to regenerate each data artifact (run from their repo dirs).
# All can be skipped with --no-rebuild. VietMap EDOG runs after the Waze rebuild
# so it merges VietMap data on top (it never drops the Waze-crawled points).
REBUILD_STEPS = [
    ("waze-diff-crawl", DECODE, [".venv/bin/python", "wme_diff_crawl.py",
              "--active-only", "--batch", "8"]),
    ("decode-mapcomments", DECODE, [".venv/bin/python", "extract_mapcomments.py"]),
    ("decode-hazards", DECODE, [".venv/bin/python", "extract_compare.py"]),
    ("build-mod-db", DECODE, [".venv/bin/python", "build_mod_db_v2.py"]),
    ("rebuild-waze-assets", REPO, ["python3", "tools/signs/rebuild_waze_assets.py"]),
    # The WME per-SEGMENT speed-limit asset (per-direction, ~95% of HCMC
    # segments). Runs straight off the crawl, so it must come after waze-crawl.
    ("build-waze-segments", REPO, ["python3", "tools/signs/build_waze_segments.py"]),
    ("build-vietmap", REPO, ["python3", "tools/signs/build_vietmap.py"]),
    ("dedup-cameras", REPO, ["python3", "tools/signs/dedup_cameras.py"]),
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

    publish(force=force)
    if UPLOAD_TARGET:
        upload(UPLOAD_TARGET)

    # Save state
    state["last_url"] = url
    state["last_published"] = time.strftime("%Y-%m-%d")
    state["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%S+07:00")
    state["edog_file"] = str(edog)
    state["edog_bytes"] = edog.stat().st_size
    save_vietmap_state(state)
    print(f"[vietmap] Update pipeline completed successfully for {url}")
    return True


def git_push_changes(msg: str = "") -> bool:
    """Stage assets/offline_map, update/, and crawl caches, then commit and push."""
    today = time.strftime("%Y-%m-%d")
    msg = msg or f"chore(data): auto-update offline datasets [KC01, WME, Police] ({today})"
    try:
        files_to_stage = [
            "assets/offline_map/waze_segments.bin",
        ]
        existing_files = [f for f in files_to_stage if (REPO / f).exists()]
        if existing_files:
            # ⛔ NO `-f` and NO policy-sensitive paths. `git add -f` bypasses both
            # .gitignore and the skip-worktree bit, so the old list (which added
            # `-f` AND `tool/data/police_crawl.json`) would have published the
            # real camera DB and the police crawl cache on a single --git-push
            # run. The data packs belong in the Release assets, not in git.
            subprocess.run(["git", "add", *existing_files], cwd=str(REPO))

        status = subprocess.check_output(
            ["git", "status", "--porcelain", "assets/offline_map", "tool/data/police_crawl.json"],
            cwd=str(REPO),
            text=True
        ).strip()
        if not status:
            print("[git] No file changes to commit.")
            return True
        print("[git] Staging and committing updated datasets...")
        subprocess.check_call(["git", "commit", "-m", msg], cwd=str(REPO))
        print("[git] Pushing changes to remote origin...")
        subprocess.check_call(["git", "push", "origin", "HEAD"], cwd=str(REPO))
        print("[git] Successfully pushed changes to origin!")
        return True
    except subprocess.CalledProcessError as e:
        print(f"[git] Git operation failed: {e}", file=sys.stderr)
        return False


def run_all_sources_pipeline(force: bool = False, budget: int = 50, crawl_police: bool = False,
                             crawl_wme: bool = True, wme_type: str = "all", git_push: bool = False):
    """Run end-to-end integration:
    1. VietMap KC01 update (build_vietmap)
    2. WME diff crawl & rebuild (wme_diff_crawl, extract, rebuild_waze_assets, build_waze_segments)
    3. Police phạt nguội crawl & geocode (fetch_police_cameras)
    4. Spatial deduplication (dedup_cameras, dedup_signs)
    5. Publish release bundle and version.json
    6. Git commit & push (if git_push requested)
    """
    print("=================================================================")
    print(" [All-Sources Pipeline] KC01 + WME + Phạt Nguội Police Crawl")
    print("=================================================================")

    # Step 1: VietMap KC01
    print("\n--> [1/5] Checking and updating VietMap KC01...")
    edog = download_vietmap(VIETMAP_DATA_DIR)
    if edog and edog.exists():
        r = subprocess.run(["python3", "tools/signs/build_vietmap.py", str(edog)], cwd=str(REPO))
        if r.returncode != 0:
            print("[vietmap] Warning: build_vietmap exited with non-zero code", file=sys.stderr)

    # Step 2: WME (Waze Map Editor) smart diff crawl & assets
    print("\n--> [2/5] WME assets (diff crawl + decode + rebuild)...")
    if crawl_wme and DECODE.exists():
        diff_script = DECODE / "wme_diff_crawl.py"
        venv_py = DECODE / ".venv" / "bin" / "python"
        py_bin = str(venv_py) if venv_py.exists() else "python3"
        if diff_script.exists():
            print(f"[wme] Running smart diff crawler (active-type: {wme_type})...")
            cmd = [py_bin, str(diff_script), "--active-type", wme_type, "--batch", "8"]
            r = subprocess.run(cmd, cwd=str(DECODE))
            if r.returncode == 0:
                print("[wme] Running decoders (extract_mapcomments, extract_compare, build_mod_db_v2)...")
                subprocess.run([py_bin, "extract_mapcomments.py"], cwd=str(DECODE))
                subprocess.run([py_bin, "extract_compare.py"], cwd=str(DECODE))
                subprocess.run([py_bin, "build_mod_db_v2.py"], cwd=str(DECODE))
            else:
                print(f"[wme] Warning: wme_diff_crawl returned non-zero code: {r.returncode}", file=sys.stderr)

    if (DECODE / "point_notices_v2.tsv").exists() or (DECODE / "vn_features").exists():
        steps = [
            ("rebuild-waze-assets", ["python3", "tools/signs/rebuild_waze_assets.py"]),
            ("build-waze-segments", ["python3", "tools/signs/build_waze_segments.py"]),
        ]
        for name, cmd in steps:
            print(f"[wme] Running {name}...")
            subprocess.run(cmd, cwd=str(REPO))
    else:
        print("[wme] Note: Decode_Waze data files not found; using existing base Waze assets.")

    # Step 3: Phạt nguội (Police CSGT) cameras
    print("\n--> [3/5] Checking provincial police phạt nguội camera data...")
    police_cache = REPO / "tool" / "data" / "police_crawl.json"
    police_cache.parent.mkdir(parents=True, exist_ok=True)

    need_crawl = crawl_police or not police_cache.exists() or police_cache.stat().st_size < 100
    if need_crawl:
        print("[police] Crawling all 63 provinces from kiemtraphatnguoi.com (official police sources)...")
        r = subprocess.run(["python3", "tool/fetch_police_cameras.py", "--all", "--crawl", "--cache", str(police_cache)], cwd=str(REPO))
        if r.returncode != 0:
            print("[police] Warning: police crawl exited with non-zero code", file=sys.stderr)

    if police_cache.exists() and police_cache.stat().st_size >= 10:
        print(f"[police] Incremental geocoding and merging (budget: {budget} Vietmap requests)...")
        cmd = ["python3", "tool/fetch_police_cameras.py", "--geocode", "--cache", str(police_cache), "--budget", str(budget), "--write"]
        r = subprocess.run(cmd, cwd=str(REPO))
        if r.returncode != 0:
            print("[police] Warning: fetch_police_cameras geocoding exited with non-zero code", file=sys.stderr)

    # Step 4: Spatial deduplication across all sources
    print("\n--> [4/5] Spatial deduplication (VietMap > WME > Police > OSM)...")
    subprocess.run(["python3", "tools/signs/dedup_cameras.py"], cwd=str(REPO))
    subprocess.run(["python3", "tools/signs/dedup_signs.py", "--write"], cwd=str(REPO))

    # Step 5: Publish release bundle
    print("\n--> [5/5] Publishing release bundle (manifest.json & version.json)...")
    publish(force=force)
    print("\n[All-Sources Pipeline] All data successfully merged and published!")

    # Step 6: Optional git commit & push
    if git_push:
        git_push_changes()



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


def publish(force: bool = False):
    validate_assets(force=force)
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

    # Compressed companions. These packs are large JSON and gzip shrinks them
    # several-fold — worth it on a phone's data plan. The client tries
    # `<name>.gz` first and falls back to the plain file, so an install that
    # predates the compressed transport keeps working unchanged.
    # `.bin` is included on purpose: the segment layer is 26 MB of packed
    # variable-length records and still gzips to ~14 MB (1.9x), which is worth
    # it on a phone's data plan.
    for name in [n for n in PUBLISH_FILES if n.endswith((".json", ".bin"))]:
        src = release / name
        gz = release / f"{name}.gz"
        with open(src, "rb") as fi, gzip.open(gz, "wb", compresslevel=9) as fo:
            shutil.copyfileobj(fi, fo)
        files[f"{name}.gz"] = {"sha256": sha256(gz), "size": gz.stat().st_size}

    # Optional offline bundles (PMTiles map, GraphHopper routing graph)
    optional_assets = [
        ("saigon_z16.pmtiles", [ASSETS / "saigon_z16.pmtiles", REPO / "tools" / "saigon_z16.pmtiles"]),
        ("routing_graph.ghz", [REPO / "tools" / "data" / "routing_graph.ghz", ASSETS / "routing_graph.ghz"]),
    ]
    for name, candidates in optional_assets:
        for c in candidates:
            if c.exists():
                dst = release / name
                shutil.copy2(c, dst)
                files[name] = {
                    "sha256": sha256(dst),
                    "size": dst.stat().st_size,
                }
                break

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
        "vietmap_limits": files.get("vietmap_speed_limits.json", {}).get("sha256", "")[:16],
        "pois": files.get("vietnam_pois.json", {}).get("sha256", "")[:16],
        "places": files.get("vietnam_places.json", {}).get("sha256", "")[:16],
        "nav_style": files.get("nav_style.json", {}).get("sha256", "")[:16],
        "overview_tiles": files.get("overview_tiles.tar.gz", {}).get("sha256", "")[:16],
        "segments": files.get("waze_segments.bin", {}).get("sha256", "")[:16],
    }
    if "routing_graph.ghz" in files:
        version_data["graph"] = files["routing_graph.ghz"]["sha256"][:16]
    if "saigon_z16.pmtiles" in files:
        version_data["navmap"] = files["saigon_z16.pmtiles"]["sha256"][:16]
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


def _materialize_latest(stage: Path) -> None:
    """Build a staging tree with `latest/` as REAL files.

    `latest` is a symlink; object stores (`gsutil rsync`) and `rclone sync` do
    not follow it, so dereference it into real directories before uploading.
    """
    if stage.exists():
        shutil.rmtree(stage)
    (stage / "releases").mkdir(parents=True)
    for r in sorted(RELEASES.glob("*")):
        if r.is_dir():
            shutil.copytree(r, stage / "releases" / r.name)
    if LATEST.exists():
        shutil.copytree(LATEST.resolve(), stage / "latest")


def get_git_repo_slug() -> str:
    """Detect 'owner/repo' from git remote origin or return default."""
    try:
        out = subprocess.check_output(
            ["git", "config", "--get", "remote.origin.url"],
            cwd=str(REPO),
            text=True
        ).strip()
        if "github.com" in out:
            return out.split("github.com")[-1].lstrip("/:").rstrip(".git")
    except Exception:
        pass
    return "DangLamTung/navbridge"


def upload_github_release(repo_slug: str, tag: str, files_dir: Path, token: str = "") -> int:
    """Upload all files in files_dir as release assets to GitHub release at repo_slug and tag."""
    token = token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if not token:
        # Check if gh CLI is available and authenticated
        if shutil.which("gh"):
            print(f"[github] Uploading release via gh CLI to {repo_slug} tag '{tag}'...")
            subprocess.run(
                ["gh", "release", "create", tag, "--repo", repo_slug,
                 "--title", f"Offline Navigation Data ({tag})",
                 "--notes", "Automated NavBridge offline data bundle (GraphHopper, PMTiles, Cameras, Signs, Limits).",
                 "--clobber"],
                cwd=str(REPO)
            )
            files = [str(p) for p in sorted(files_dir.iterdir()) if p.is_file()]
            if files:
                rc = subprocess.call(["gh", "release", "upload", tag, *files, "--repo", repo_slug, "--clobber"], cwd=str(REPO))
                if rc == 0:
                    print(f"\n[github] SUCCESS! Direct download URLs:")
                    for f in sorted(files_dir.iterdir()):
                        if f.is_file():
                            print(f"  https://github.com/{repo_slug}/releases/download/{tag}/{f.name}")
                    print(f"\nConfigure in NavBridge:")
                    print(f"  DATA_URL:   https://github.com/{repo_slug}/releases/download/{tag}")
                    print(f"  NAVMAP_URL: https://github.com/{repo_slug}/releases/download/{tag}/saigon_z16.pmtiles")
                    print(f"  GRAPH_URL:  https://github.com/{repo_slug}/releases/download/{tag}/routing_graph.ghz")
                    return 0
                return rc
        print("[github] ERROR: GITHUB_TOKEN not found in environment and gh CLI not available.", file=sys.stderr)
        print("         Please set export GITHUB_TOKEN=ghp_... or install gh CLI (brew install gh).", file=sys.stderr)
        return 1

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "NavBridge-DataUpdater",
    }

    rel_url = f"https://api.github.com/repos/{repo_slug}/releases/tags/{tag}"
    req = urllib.request.Request(rel_url, headers=headers)
    release_info = None
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status == 200:
                release_info = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print(f"[github] Error checking release {tag}: {e}", file=sys.stderr)
            return 1

    if not release_info:
        create_url = f"https://api.github.com/repos/{repo_slug}/releases"
        payload = json.dumps({
            "tag_name": tag,
            "name": f"Offline Navigation Data ({tag})",
            "body": "Automated NavBridge offline data bundle (GraphHopper, PMTiles, Cameras, Signs, Limits).",
            "draft": False,
            "prerelease": False
        }).encode("utf-8")
        creq = urllib.request.Request(create_url, data=payload, headers={**headers, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(creq) as resp:
                release_info = json.loads(resp.read().decode())
                print(f"[github] Created new release for tag '{tag}'")
        except Exception as e:
            print(f"[github] Failed to create release: {e}", file=sys.stderr)
            return 1

    upload_url_tmpl = release_info["upload_url"].split("{")[0]
    existing_assets = {a["name"]: a["id"] for a in release_info.get("assets", [])}

    files = [p for p in sorted(files_dir.iterdir()) if p.is_file()]
    print(f"[github] Uploading {len(files)} files to {repo_slug} (tag '{tag}')...")

    for f in files:
        if f.name in existing_assets:
            del_url = f"https://api.github.com/repos/{repo_slug}/releases/assets/{existing_assets[f.name]}"
            dreq = urllib.request.Request(del_url, headers=headers, method="DELETE")
            try:
                with urllib.request.urlopen(dreq):
                    pass
            except Exception:
                pass

        size_mb = f.stat().st_size / (1024 * 1024)
        print(f"  -> Uploading {f.name} ({size_mb:.2f} MB)...", end="", flush=True)

        up_url = f"{upload_url_tmpl}?name={urllib.parse.quote(f.name)}"
        with open(f, "rb") as fp:
            data = fp.read()
        ureq = urllib.request.Request(up_url, data=data, headers={
            **headers,
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(data)),
        })
        try:
            with urllib.request.urlopen(ureq) as resp:
                if resp.status in (200, 201):
                    print(" OK")
                else:
                    print(f" Status {resp.status}")
        except Exception as e:
            print(f" Failed: {e}", file=sys.stderr)
            return 1

    print(f"\n[github] SUCCESS! Direct download URLs:")
    for f in files:
        print(f"  https://github.com/{repo_slug}/releases/download/{tag}/{f.name}")
    print(f"\nConfigure in NavBridge:")
    print(f"  DATA_URL:   https://github.com/{repo_slug}/releases/download/{tag}")
    print(f"  NAVMAP_URL: https://github.com/{repo_slug}/releases/download/{tag}/saigon_z16.pmtiles")
    print(f"  GRAPH_URL:  https://github.com/{repo_slug}/releases/download/{tag}/routing_graph.ghz")
    return 0


def build_graph(region: str = "saigon") -> Path:
    """Download PBF if needed and build GraphHopper .ghz graph."""
    print(f"\n[graph] Building GraphHopper routing graph for region '{region}'...")
    cmd = ["bash", str(REPO / "tools" / "auto_create_graph.sh"), region]
    r = subprocess.run(cmd, cwd=str(REPO))
    if r.returncode != 0:
        print(f"[graph] FAILED building graph (exit {r.returncode})", file=sys.stderr)
        sys.exit(r.returncode)
    ghz = REPO / "tools" / "data" / "routing_graph.ghz"
    if not ghz.exists():
        candidates = list((REPO / "tools" / "data").glob("*.ghz"))
        if candidates:
            ghz = candidates[0]
    print(f"[graph] Graph ready at: {ghz} ({ghz.stat().st_size / (1024*1024):.1f} MB)\n")
    return ghz


def upload(target: str) -> int:
    """Copy the published bundles to TARGET — a place to store them.

    TARGET forms:
      github[:<repo>]      GitHub Releases (free host, direct download URLs)
      rclone:remote:path   anything rclone reaches — Google Drive, S3, B2…
      gdrive:path          alias for rclone Google Drive remote
      gs://bucket/prefix   Google Cloud Storage (gsutil)
      /path or ~/path      a local dir, NAS, or a mounted Google Drive
    """
    if not RELEASES.exists():
        print("[upload] nothing published yet — run --publish first",
              file=sys.stderr)
        return 1

    stage = REPO / "update" / ".upload"
    _materialize_latest(stage)

    if target.startswith("github"):
        parts = target.split(":", 1)
        repo_slug = parts[1].strip() if len(parts) > 1 and parts[1].strip() else get_git_repo_slug()
        tag = os.environ.get("RELEASE_TAG", "offline-data-latest")
        rc = upload_github_release(repo_slug, tag, stage / "latest")
        shutil.rmtree(stage, ignore_errors=True)
        return rc
    elif target.startswith("gs://"):
        if not shutil.which("gsutil"):
            print("[upload] gsutil not found on PATH", file=sys.stderr)
            return 1
        cmd = ["gsutil", "-m", "rsync", "-r", str(stage), target.rstrip("/")]
    elif target.startswith("rclone:") or target.startswith("gdrive:"):
        remote = target[len("rclone:"):] if target.startswith("rclone:") else target
        if not shutil.which("rclone"):
            print("[upload] rclone not found — install it via 'brew install rclone' to sync with Google Drive", file=sys.stderr)
            print("         Or configure with: rclone config", file=sys.stderr)
            return 1
        cmd = ["rclone", "sync", str(stage / "latest"), f"{remote.rstrip('/')}/latest"]
    else:
        dest = Path(os.path.expanduser(target))
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stage, dest, dirs_exist_ok=True)
        shutil.rmtree(stage, ignore_errors=True)
        print(f"[upload] copied update/ -> {dest}")
        return 0

    print(f"[upload] {' '.join(cmd)}")
    rc = subprocess.call(cmd)
    shutil.rmtree(stage, ignore_errors=True)
    if rc != 0:
        print(f"[upload] FAILED (exit {rc})", file=sys.stderr)
    else:
        print(f"[upload] done -> {target}")
    return rc


class Handler(SimpleHTTPRequestHandler):
    """Serve the update dir with file upload dashboard and auto update links."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(REPO / "update"), **kwargs)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        host = self.headers.get("Host", "localhost:8080")
        auto_update_link = f"http://{host}/latest"

        if self.path in ("/", "/upload", "/dashboard"):
            self._render_dashboard(auto_update_link)
            return

        if self.path in ("/wme-auth", "/auth", "/login-waze"):
            self._render_wme_auth(auto_update_link)
            return

        if self.path in ("/api/wme-status", "/status/wme"):
            is_valid = check_wme_session()
            self._send_json(200, {
                "session_valid": is_valid,
                "crawl": CRAWL_STATUS,
            })
            return

        if self.path in ("/api/info", "/info"):
            self._render_info(auto_update_link)
            return

        super().do_GET()

    def do_POST(self):
        host = self.headers.get("Host", "localhost:8080")
        auto_update_link = f"http://{host}/latest"

        if self.path in ("/api/publish", "/publish"):
            try:
                publish(force=True)
                self._send_json(200, {
                    "status": "ok",
                    "message": "Bundle published successfully",
                    "auto_update_link": auto_update_link,
                })
            except Exception as e:
                self._send_json(500, {"status": "error", "message": str(e)})
            return

        if self.path.startswith(("/upload", "/api/upload")):
            self._handle_upload(auto_update_link)
            return

        if self.path in ("/api/wme-cookie", "/wme-auth"):
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length).decode("utf-8", errors="replace").strip()
            cookie = ""
            if raw_body.startswith("{"):
                try:
                    payload = json.loads(raw_body)
                    cookie = payload.get("cookie", "").strip()
                except Exception:
                    cookie = raw_body
            else:
                if "=" in raw_body and ("cookie=" in raw_body.lower() or "token=" in raw_body.lower()):
                    parsed = urllib.parse.parse_qs(raw_body)
                    cookie = parsed.get("cookie", parsed.get("token", [""]))[0].strip()
                else:
                    cookie = raw_body

            if not cookie:
                self._send_json(400, {"status": "error", "valid": False, "message": "Cookie rỗng."})
                return

            print(f"[WME Auth] Received cookie length {len(cookie)}. Verifying...")
            is_valid = check_wme_session(cookie)
            if not is_valid:
                self._send_json(401, {
                    "status": "error",
                    "valid": False,
                    "message": "Cookie không hợp lệ hoặc phiên WME đã hết hạn. Hãy đăng nhập lại WME rồi thử lại."
                })
                return

            start_crawl_pipeline_background(cookie)
            self._send_json(200, {
                "status": "ok",
                "valid": True,
                "message": "Cookie hợp lệ! Tiến trình cào và cập nhật dữ liệu tự động đã bắt đầu ngầm. App sẽ nhận được bản cập nhật khi hoàn tất."
            })
            return

        if self.path in ("/api/send-auth-email", "/notify-email"):
            cmd = ["python3", str(REPO / "tools" / "wme_auth_notifier.py"), "--force-mail", "--server-url", f"http://{host}"]
            res = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True)
            self._send_json(200, {
                "status": "ok" if res.returncode == 0 else "notice",
                "message": res.stdout.strip() or res.stderr.strip()
            })
            return

        self._send_json(404, {"error": "Not found"})

    def _render_info(self, auto_update_link: str):
        v_file = LATEST / "version.json"
        version_data = {}
        if v_file.exists():
            try:
                with open(v_file, encoding="utf-8") as f:
                    version_data = json.load(f)
            except Exception:
                pass

        m_file = LATEST / "manifest.json"
        manifest_data = {}
        if m_file.exists():
            try:
                with open(m_file, encoding="utf-8") as f:
                    manifest_data = json.load(f)
            except Exception:
                pass

        self._send_json(200, {
            "status": "ok",
            "auto_update_link": auto_update_link,
            "version": version_data,
            "manifest": manifest_data,
            "files": {
                name: {
                    "url": f"{auto_update_link}/{name}",
                    "size": meta.get("size"),
                    "sha256": meta.get("sha256"),
                }
                for name, meta in manifest_data.get("files", {}).items()
            },
        })

    def _render_dashboard(self, auto_update_link: str):
        v_file = LATEST / "version.json"
        versions = {}
        if v_file.exists():
            try:
                with open(v_file, encoding="utf-8") as f:
                    versions = json.load(f)
            except Exception:
                pass

        html = f"""<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NavBridge Offline Data Upload Server</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 24px; background: #f8f9fa; color: #202124; }}
  .container {{ max-width: 800px; margin: 0 auto; background: white; padding: 28px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,0.08); }}
  h1 {{ margin-top: 0; color: #1a73e8; font-size: 24px; }}
  .link-box {{ background: #e8f0fe; border: 1px solid #c2e7ff; padding: 16px; border-radius: 8px; margin: 18px 0; }}
  .link-title {{ font-size: 13px; font-weight: 700; color: #0b57d0; text-transform: uppercase; letter-spacing: 0.5px; }}
  .link-url {{ font-family: monospace; font-size: 16px; font-weight: bold; margin: 8px 0; color: #1f1f1f; word-break: break-all; }}
  .badge {{ display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; background: #e6f4ea; color: #137333; }}
  .upload-card {{ border: 2px dashed #dadce0; border-radius: 10px; padding: 24px; text-align: center; margin: 20px 0; background: #fafafa; }}
  .btn {{ background: #1a73e8; color: white; border: none; padding: 10px 20px; font-size: 14px; font-weight: bold; border-radius: 6px; cursor: pointer; }}
  .btn:hover {{ background: #1557b0; }}
  table {{ width: 100%; border-collapse: collapse; margin-top: 14px; }}
  th, td {{ padding: 10px; text-align: left; border-bottom: 1px solid #eee; font-size: 13px; }}
  th {{ color: #5f6368; }}
  code {{ font-family: monospace; background: #f1f3f4; padding: 2px 5px; border-radius: 3px; font-size: 12px; }}
</style>
</head>
<body>
<div class="container">
  <h1>🚀 NavBridge Offline Data Server</h1>
  <p>Máy chủ lưu trữ, cập nhật tự động và tải lên dữ liệu biển báo, tốc độ, camera cho ứng dụng NavBridge.</p>
  
  <div class="link-box">
    <div class="link-title">🔗 Auto Update Link (DATA_URL)</div>
    <div class="link-url" id="autoLink">{auto_update_link}</div>
    <div style="font-size: 12px; color: #555;">Dán liên kết này vào ứng dụng NavBridge (⚙ Cài đặt → Nguồn dữ liệu → DATA_URL).</div>
  </div>

  <div style="background: #f0f7ff; border: 1px solid #b8daff; border-radius: 8px; padding: 18px; margin: 18px 0;">
    <div style="display: flex; justify-content: space-between; align-items: center;">
      <div>
        <h3 style="margin: 0 0 6px 0; color: #004085;">🔑 Waze WME Crawler & Cấp Token</h3>
        <div style="font-size: 13px; color: #555;">Trạng thái phiên WME hiện tại: <span class="badge" style="background: {'#e6f4ea' if check_wme_session() else '#fce8e6'}; color: {'#137333' if check_wme_session() else '#c5221f'};">{'✅ Hoạt động' if check_wme_session() else '⚠️ Hết hạn / Cần cấp token'}</span></div>
      </div>
      <div>
        <a href="/wme-auth" class="btn" style="text-decoration:none;">Mở Cổng Cấp Token WME →</a>
      </div>
    </div>
  </div>

  <h3>📤 Tải lên dữ liệu mới (Sign / Speed / Camera)</h3>
  <div class="upload-card">
    <form action="/upload" method="post" enctype="multipart/form-data">
      <p style="margin-top:0;">Chọn một hoặc nhiều tệp: <code>vietnam_signs.json</code>, <code>vietnam_cameras.json</code>, <code>waze_speed_limits.json</code>, <code>waze_segments.bin</code></p>
      <input type="file" name="files" multiple required style="margin-bottom: 16px;"><br>
      <button type="submit" class="btn">Tải lên & Tự động xuất bản</button>
    </form>
  </div>

  <h3>📊 Trạng thái dữ liệu hiện hành (latest)</h3>
  <table>
    <thead><tr><th>Loại dữ liệu</th><th>Tên tệp</th><th>Phiên bản (Hash)</th><th>Tải trực tiếp</th></tr></thead>
    <tbody>
      <tr><td>Biển báo</td><td>vietnam_signs.json</td><td><code>{versions.get('signs', 'chưa có')}</code></td><td><a href="/latest/vietnam_signs.json">Tải về</a></td></tr>
      <tr><td>Camera giao thông</td><td>vietnam_cameras.json</td><td><code>{versions.get('cameras', 'chưa có')}</code></td><td><a href="/latest/vietnam_cameras.json">Tải về</a></td></tr>
      <tr><td>Giới hạn tốc độ Waze</td><td>waze_speed_limits.json</td><td><code>{versions.get('speed_limits', 'chưa có')}</code></td><td><a href="/latest/waze_speed_limits.json">Tải về</a></td></tr>
      <tr><td>Đoạn đường Waze</td><td>waze_segments.bin</td><td><span class="badge">Binary Layer</span></td><td><a href="/latest/waze_segments.bin">Tải về</a></td></tr>
    </tbody>
  </table>

  <div style="margin-top: 24px; font-size: 12px; color: #70757a;">
    💡 <b>Mẹo cập nhật qua lệnh cURL:</b><br>
    <code>curl -F "file=@vietnam_signs.json" {auto_update_link.replace('/latest', '')}/upload</code>
  </div>
</div>
</body>
</html>"""
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _render_wme_auth(self, auto_update_link: str):
        host = self.headers.get("Host", "localhost:8080")
        base_url = f"http://{host}"
        is_valid = check_wme_session()

        bookmarklet_code = f"""javascript:(function(){{var c=document.cookie;if(!c){{alert('Chưa có cookie WME! Hãy đăng nhập trước.');return;}}fetch('{base_url}/api/wme-cookie',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{cookie:c}})}}).then(r=>r.json()).then(d=>{{if(d.valid){{alert('✅ Cookie hợp lệ! Server đã bắt đầu cào dữ liệu...');location.href='{base_url}/wme-auth';}}else{{alert('❌ '+d.message);}}}}).catch(e=>alert('Lỗi kết nối tới Server: '+e));}})();"""

        html = f"""<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NavBridge - Cấp Token WME & Kích Hoạt Cào Dữ Liệu</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 24px; background: #f0f4f8; color: #1e293b; }}
  .container {{ max-width: 760px; margin: 0 auto; background: white; padding: 32px; border-radius: 14px; box-shadow: 0 4px 20px rgba(0,0,0,0.06); }}
  h1 {{ margin-top: 0; color: #0284c7; font-size: 22px; display: flex; align-items: center; gap: 8px; }}
  .status-badge {{ display: inline-block; padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: bold; }}
  .status-ok {{ background: #dcfce7; color: #15803d; }}
  .status-warn {{ background: #fee2e2; color: #b91c1c; }}
  .step-card {{ border: 1px solid #e2e8f0; border-radius: 10px; padding: 20px; margin: 18px 0; background: #f8fafc; }}
  .step-title {{ font-weight: bold; font-size: 15px; margin-bottom: 8px; color: #0369a1; }}
  .btn {{ display: inline-block; background: #0284c7; color: white; border: none; padding: 10px 18px; font-size: 14px; font-weight: 600; border-radius: 8px; cursor: pointer; text-decoration: none; }}
  .btn:hover {{ background: #0369a1; }}
  .btn-bm {{ background: #f59e0b; color: white; padding: 8px 14px; border-radius: 6px; font-size: 13px; text-decoration: none; font-weight: 600; }}
  .btn-bm:hover {{ background: #d97706; }}
  textarea {{ width: 100%; box-sizing: border-box; font-family: monospace; font-size: 12px; padding: 10px; border: 1px solid #cbd5e1; border-radius: 6px; }}
  .progress-box {{ background: #1e293b; color: #f8fafc; padding: 16px; border-radius: 8px; font-family: monospace; font-size: 13px; margin-top: 14px; }}
</style>
</head>
<body>
<div class="container">
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <h1>🔑 WME Authentication & Auto-Crawl Portal</h1>
    <a href="/" style="font-size:13px; text-decoration:none; color:#64748b;">← Dashboard</a>
  </div>
  <p>Cấp phiên đăng nhập <b>WME (Waze Map Editor)</b> để máy chủ tự động cào dữ liệu biển báo, đoạn đường, tốc độ và đẩy phiên bản mới về app NavBridge.</p>

  <div style="margin: 16px 0; padding: 12px 16px; background: #f1f5f9; border-radius: 8px; display: flex; align-items: center; justify-content: space-between;">
    <div><b>Trạng thái WME hiện tại:</b> <span class="status-badge {'status-ok' if is_valid else 'status-warn'}">{'✅ Phiên WME hợp lệ' if is_valid else '⚠️ Phiên WME hết hạn / Chưa có token'}</span></div>
    <button onclick="sendMail()" class="btn" style="background:#64748b; font-size:12px; padding:6px 12px;">📧 Gửi Email Thông Báo</button>
  </div>

  <!-- BƯỚC 1 -->
  <div class="step-card">
    <div class="step-title">Bước 1: Đăng nhập tài khoản Waze Map Editor</div>
    <p style="margin:4px 0 12px 0; font-size:13px; color:#475569;">Mở WME trong tab mới và đăng nhập bằng tài khoản Google / Waze của bạn:</p>
    <a href="https://www.waze.com/editor" target="_blank" class="btn">🌐 Mở Waze Map Editor (waze.com/editor)</a>
  </div>

  <!-- BƯỚC 2 -->
  <div class="step-card">
    <div class="step-title">Bước 2 (Tiện lợi nhất): Bookmarklet 1 Chạm</div>
    <p style="margin:4px 0 10px 0; font-size:13px; color:#475569;">Kéo nút màu cam dưới đây vào <b>Thanh Dấu Trang (Bookmarks Bar)</b> của trình duyệt. Khi đang ở tab <code>waze.com/editor</code>, chỉ cần bấm vào bookmark này là cookie sẽ tự động gửi về Server:</p>
    <div style="margin: 12px 0;">
      <a class="btn-bm" href="{bookmarklet_code}">⭐ Gửi Cookie WME về NavBridge</a>
    </div>
    <div style="font-size: 11px; color: #64748b;">(Hoặc kéo nút trên thả vào Bookmarks Bar trình duyệt của bạn)</div>
  </div>

  <!-- BƯỚC 3 -->
  <div class="step-card">
    <div class="step-title">Bước 3 (Thủ công): Dán Cookie hoặc Token vào đây</div>
    <p style="margin:4px 0 8px 0; font-size:13px; color:#475569;">Dán chuỗi cookie (từ DevTools hoặc extension) vào ô dưới đây và bấm kích hoạt:</p>
    <textarea id="cookieInput" rows="3" placeholder="_waze_session=...; or full Cookie header"></textarea>
    <div style="margin-top: 10px;">
      <button onclick="submitCookie()" class="btn" id="submitBtn">🚀 Xác Thực Cookie & Bắt Đầu Cào Dữ Liệu</button>
    </div>
    <div id="submitResult" style="margin-top: 8px; font-size: 13px; font-weight: bold;"></div>
  </div>

  <!-- BƯỚC 4: TIẾN TRÌNH CÀO -->
  <div class="step-card" style="background:#0f172a; color:#e2e8f0;">
    <div class="step-title" style="color:#38bdf8;">⚡ Tiến trình Cào & Đồng bộ App (Thời gian thực)</div>
    <div class="progress-box" id="progressBox">Đang nạp trạng thái...</div>
  </div>
</div>

<script>
async function submitCookie() {{
  const val = document.getElementById('cookieInput').value.trim();
  if (!val) {{ alert('Vui lòng dán cookie!'); return; }}
  const btn = document.getElementById('submitBtn');
  const resDiv = document.getElementById('submitResult');
  btn.disabled = true;
  btn.innerText = 'Đang xác thực với Waze...';
  resDiv.innerText = '';

  try {{
    const res = await fetch('/api/wme-cookie', {{
      method: 'POST',
      headers: {{ 'Content-Type': 'application/json' }},
      body: JSON.stringify({{ cookie: val }})
    }});
    const data = await res.json();
    if (data.valid) {{
      resDiv.style.color = '#15803d';
      resDiv.innerText = '✅ ' + data.message;
      pollStatus();
    }} else {{
      resDiv.style.color = '#b91c1c';
      resDiv.innerText = '❌ ' + data.message;
    }}
  }} catch(e) {{
    resDiv.style.color = '#b91c1c';
    resDiv.innerText = 'Lỗi kết nối: ' + e;
  }} finally {{
    btn.disabled = false;
    btn.innerText = '🚀 Xác Thực Cookie & Bắt Đầu Cào Dữ Liệu';
  }}
}}

async function sendMail() {{
  try {{
    const res = await fetch('/api/send-auth-email', {{ method: 'POST' }});
    const data = await res.json();
    alert('Đã gửi email thông báo: ' + (data.message || 'OK'));
  }} catch(e) {{
    alert('Lỗi: ' + e);
  }}
}}

async function pollStatus() {{
  try {{
    const res = await fetch('/api/wme-status');
    const data = await res.json();
    const box = document.getElementById('progressBox');
    const c = data.crawl || {{}};
    let text = 'Trạng thái cào: ' + (c.status || 'idle').toUpperCase() + '\\n';
    text += 'Tiến độ: ' + (c.progress || 'Sẵn sàng') + '\\n';
    if (c.started_at) text += 'Bắt đầu lúc: ' + c.started_at + '\\n';
    if (c.finished_at) text += 'Hoàn thành lúc: ' + c.finished_at + '\\n';
    if (c.error) text += 'Lỗi: ' + c.error + '\\n';
    box.innerText = text;
  }} catch(_) {{}}
}}

setInterval(pollStatus, 2500);
pollStatus();
</script>
</body>
</html>"""
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle_upload(self, auto_update_link: str):
        content_type = self.headers.get("Content-Type", "")
        content_len = int(self.headers.get("Content-Length", 0))

        if content_len == 0:
            self._send_json(400, {"status": "error", "message": "Empty body"})
            return

        body = self.rfile.read(content_len)
        saved_files = []

        allowed_files = {
            "vietnam_signs.json",
            "vietnam_cameras.json",
            "waze_speed_limits.json",
            "waze_segments.bin",
        }

        # Check multipart boundary
        if "boundary=" in content_type:
            boundary = content_type.split("boundary=")[1].strip()
            parts = body.split(b"--" + boundary.encode())
            for part in parts:
                if b'filename="' in part:
                    header, data = part.split(b"\r\n\r\n", 1)
                    header_str = header.decode("latin1", "replace")
                    fn_match = re.search(r'filename="([^"]+)"', header_str)
                    if fn_match:
                        fname = os.path.basename(fn_match.group(1))
                        if fname in allowed_files:
                            content = data.rstrip(b"\r\n--")
                            target = ASSETS / fname
                            with open(target, "wb") as f:
                                f.write(content)
                            saved_files.append(fname)
        else:
            # Single raw upload with Query Param or Header
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            fname = params.get("filename", [""])[0] or self.headers.get("X-Filename", "")
            if fname in allowed_files:
                target = ASSETS / fname
                with open(target, "wb") as f:
                    f.write(body)
                saved_files.append(fname)

        if not saved_files:
            self._send_json(400, {
                "status": "error",
                "message": f"No allowed files found. Allowed names: {list(allowed_files)}",
            })
            return

        try:
            # Auto-publish updated assets
            publish(force=True)
            self._send_json(200, {
                "status": "ok",
                "message": f"Successfully updated and published {len(saved_files)} file(s).",
                "saved_files": saved_files,
                "auto_update_link": auto_update_link,
            })
        except Exception as e:
            self._send_json(500, {
                "status": "error",
                "message": f"Saved files but publish failed: {e}",
            })

    def _send_json(self, status: int, data: dict):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # quiet


def serve(port: int, tunnel: bool = False):
    os.chdir(REPO / "update")
    handler = lambda *a, **k: Handler(*a, **k)
    httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    print(f"[serve] Local server running at http://0.0.0.0:{port}/latest/manifest.json")
    if tunnel:
        if shutil.which("cloudflared"):
            print("[tunnel] Starting Cloudflare Quick Tunnel (free public HTTPS)...")
            t_cmd = ["cloudflared", "tunnel", "--url", f"http://127.0.0.1:{port}"]
            p = subprocess.Popen(t_cmd, stderr=subprocess.PIPE, text=True)

            def watch_tunnel():
                for line in p.stderr:
                    if ".trycloudflare.com" in line:
                        for word in line.split():
                            if "trycloudflare.com" in word:
                                url = word.strip().rstrip("/")
                                print(f"\n[tunnel] ****************************************************")
                                print(f"[tunnel] FREE PUBLIC HTTPS URL: {url}")
                                print(f"[tunnel] NavBridge DATA_URL:    {url}/latest")
                                print(f"[tunnel] NavBridge NAVMAP_URL:  {url}/latest")
                                print(f"[tunnel] ****************************************************\n")
            import threading
            threading.Thread(target=watch_tunnel, daemon=True).start()
        else:
            print("[tunnel] Tip: install 'cloudflared' (brew install cloudflared) for instant free public HTTPS tunnel.")
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
                    help="force rebuild even if state exists / bypass size validation")
    ap.add_argument("--all-sources", action="store_true",
                    help="run end-to-end integration: VietMap KC01 + WME + Police phạt nguội crawl + dedup + publish")
    ap.add_argument("--budget", type=int, default=50,
                    help="request budget for police camera geocoding (default: 50)")
    ap.add_argument("--build-graph", nargs="?", const="saigon", metavar="REGION",
                    help="download PBF & build GraphHopper .ghz graph for region (default: saigon)")
    ap.add_argument("--build-all", nargs="?", const="saigon", metavar="REGION",
                    help="run VietMap update + build GraphHopper + publish full bundle (region default: saigon)")
    ap.add_argument("--tunnel", action="store_true",
                    help="with --serve: open a free Cloudflare Quick Tunnel for a public HTTPS URL")
    ap.add_argument("--serve", action="store_true", help="serve the releases over HTTP")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--crawl-police", action="store_true",
                    help="force re-crawl of provincial police phạt nguội camera lists")
    ap.add_argument("--crawl-wme", action="store_true", default=True,
                    help="run smart WME diff crawl before rebuilding (default: True)")
    ap.add_argument("--no-crawl-wme", action="store_false", dest="crawl_wme",
                    help="skip smart WME diff crawl")
    ap.add_argument("--wme-type", choices=["all", "cameras", "signs", "speeds"], default="all",
                    help="filter active tiles for WME crawl: all|cameras|signs|speeds (default: all)")
    ap.add_argument("--git-push", action="store_true",
                    help="git commit and push updated datasets to remote origin if changed")
    ap.add_argument("--upload", metavar="TARGET", default=UPLOAD_TARGET,
                    help="after publishing, copy update/ to TARGET: "
                         "github[:<repo>] | rclone:remote:path | gdrive:path | gs://bucket/prefix | /local/path. "
                         "Defaults to $UPLOAD_TARGET (empty = local only).")
    args = ap.parse_args()

    if args.build_graph:
        build_graph(args.build_graph)

    if args.all_sources:
        run_all_sources_pipeline(
            force=args.force,
            budget=args.budget,
            crawl_police=args.crawl_police,
            crawl_wme=args.crawl_wme,
            wme_type=args.wme_type,
            git_push=args.git_push,
        )
        if args.upload:
            sys.exit(upload(args.upload))
    elif args.build_all:
        print("[build-all] Step 1/3: Checking/updating VietMap warning data...")
        run_vietmap_pipeline(force=args.force)
        print(f"[build-all] Step 2/3: Building GraphHopper graph for '{args.build_all}'...")
        build_graph(args.build_all)
        print("[build-all] Step 3/3: Publishing complete release bundle...")
        publish(force=True)
        if args.upload:
            sys.exit(upload(args.upload))
    elif args.check_only:
        run_vietmap_pipeline(check_only=True)
    elif args.vietmap_only:
        run_vietmap_pipeline(force=args.force)
    elif args.publish:
        if args.rebuild:
            run_steps(no_vietmap=args.no_vietmap)
        publish(force=args.force)
        if args.upload:
            sys.exit(upload(args.upload))
    elif args.upload:
        sys.exit(upload(args.upload))
    elif args.serve:
        serve(args.port, tunnel=args.tunnel)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
