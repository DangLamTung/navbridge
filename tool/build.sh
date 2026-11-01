#!/usr/bin/env bash
# Build the navbridge APK with the keys from .env (local only, never committed).
#   tool/build.sh                 # flutter build apk --debug
#   tool/build.sh --release       # flutter build apk --release
#   tool/build.sh --profile       # flutter build apk --profile
#   tool/build.sh --release --no-keys
#
# ⭐ `--no-keys` builds an APK with NO provider keys compiled in. A key passed via
# --dart-define ends up readable inside the APK (see docs/google-keys.md), so a
# build that leaves the machine — or an online build for a device you do not
# control — should carry none. The keyless chain already works end to end: OSM /
# CARTO tiles need no key, OSRM routes without one, Photon geocodes without one,
# and the paid layers (Google Maps basemap, Vietmap, CARTO key, AI, Windy) simply
# hide themselves or fall back, while AI/Windy/Google keys can still be entered
# IN-APP and stored encrypted (flutter_secure_storage).
set -euo pipefail
cd "$(dirname "$0")/.."

NO_KEYS=0
for arg in "$@"; do
  [[ "$arg" == "--no-keys" ]] && NO_KEYS=1
done
if [[ "$NO_KEYS" == "1" ]]; then
  # Deliberately NOT sourcing tool/env.sh: an empty define list is the point.
  DART_DEFINES=()
  echo "build: --no-keys — nothing from .env will be compiled in"
else
  source tool/env.sh
fi

mode="debug"
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) mode="release"; shift ;;
    --profile) mode="profile"; shift ;;
    --debug) mode="debug"; shift ;;
    --no-keys) shift ;;  # already handled above
    *) extra_args+=("$1"); shift ;;
  esac
done

if [[ "${SKIP_SIGN_GATE:-0}" != "1" && "$mode" != "debug" ]]; then
  python3 tools/signs/validate_sign_placement.py
fi

exec flutter build apk --"$mode" ${DART_DEFINES[@]+"${DART_DEFINES[@]}"} ${extra_args[@]+"${extra_args[@]}"}
