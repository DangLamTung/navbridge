#!/usr/bin/env bash
# Serve the NavBridge auto-update data folder over HTTP, so a phone on the same
# LAN can pull the latest camera / road-sign JSON without installing a new APK.
#
# Usage:
#   bash tool/serve_data.sh                 # serve assets/offline_map on :8080
#   bash tool/serve_data.sh --port 9090     # port override
#
# It writes a `version.json` (per-file content hashes) into a temp dir and
# serves BOTH the generated version.json and the bundled JSON files, so the
# app's OfflineDataUpdater can check/hash and download them.
#
# Point the app at this server by setting DATA_URL in .env to the host's LAN
# IP (e.g. DATA_URL=http://192.168.1.10:8080) and rebuilding.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="8080"
if [[ "${1:-}" == "--port" ]]; then PORT="${2:?port required}"; fi

SRC="assets/offline_map"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

echo "Generating version.json from $SRC ..."
# A tiny JSON map: filename -> sha256 (short). The app treats a changed hash
# as "new data available" and downloads the file.
python3 - "$SRC" "$DIR/version.json" <<'PY'
import hashlib, json, os, sys
src, out = sys.argv[1], sys.argv[2]
ver = {}
for name in ("vietnam_cameras.json", "vietnam_signs.json"):
    p = os.path.join(src, name)
    if os.path.exists(p):
        ver[name.replace(".json", "")] = hashlib.sha256(
            open(p, "rb").read()).hexdigest()[:16]
json.dump(ver, open(out, "w"))
print("version.json ->", json.dumps(ver))
PY

# Copy the data files next to version.json so they're actually served —
# `--directory "$DIR"` only exposes the temp dir, so without this every data
# fetch 404s.
for name in vietnam_cameras.json vietnam_signs.json; do
  if [[ -f "$SRC/$name" ]]; then cp "$SRC/$name" "$DIR/"; fi
done

# Serve the whole folder (version.json + the JSON data files) on LAN.
echo "Serving on http://0.0.0.0:$PORT  (LAN IP: $(ipconfig getifaddr en0 2>/dev/null || echo unknown))"
echo "Files served: version.json, vietnam_cameras.json, vietnam_signs.json"
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DIR"
