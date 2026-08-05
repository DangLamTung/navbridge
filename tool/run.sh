#!/usr/bin/env bash
# Run navbridge with the Vietmap keys from .env (local only, never committed).
#   tool/run.sh                 # run on the default device/emulator
#   tool/run.sh -d <deviceId>   # extra flutter run args pass through
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/env.sh
exec flutter run "${DART_DEFINES[@]}" "$@"
