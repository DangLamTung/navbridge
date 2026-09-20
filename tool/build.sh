#!/usr/bin/env bash
# Build the navbridge APK with the Vietmap keys from .env (local only,
# never committed).
#   tool/build.sh            # flutter build apk --debug
#   tool/build.sh --release  # flutter build apk --release
#   tool/build.sh --profile  # flutter build apk --profile
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/env.sh

mode="debug"
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) mode="release"; shift ;;
    --profile) mode="profile"; shift ;;
    --debug) mode="debug"; shift ;;
    *) extra_args+=("$1"); shift ;;
  esac
done

exec flutter build apk --"$mode" ${DART_DEFINES[@]+"${DART_DEFINES[@]}"} ${extra_args[@]+"${extra_args[@]}"}
