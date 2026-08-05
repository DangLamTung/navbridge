#!/usr/bin/env bash
# Format-checks the .dart files passed by pre-commit (staged files only).
# Existing code is intentionally not reformatted wholesale.
#
# NOTE: must stay compatible with macOS bash 3.2 (no `mapfile`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DART_BIN="${DART_BIN:-dart}"
if ! command -v "$DART_BIN" >/dev/null 2>&1; then
  if [[ -x "$HOME/Documents/Eink/flutter_sdk/bin/dart" ]]; then
    DART_BIN="$HOME/Documents/Eink/flutter_sdk/bin/dart"
  else
    echo "error: dart not found on PATH" >&2
    exit 1
  fi
fi

# Collect the existing .dart files from the arguments.
files=()
for f in "$@"; do
  case "$f" in
    *.dart)
      if [[ -f "$f" ]]; then
        files+=("$f")
      fi
      ;;
  esac
done
if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

"$DART_BIN" format --output=none --set-exit-if-changed "${files[@]}"
