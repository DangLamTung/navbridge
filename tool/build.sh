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
case "${1:-}" in
  --release) mode="release" ;;
  --profile) mode="profile" ;;
  "") ;;
  *) echo "Unknown arg: $1 (use --release or --profile)" >&2; exit 1 ;;
esac

exec flutter build apk --"$mode" "${DART_DEFINES[@]}"
