#!/usr/bin/env bash
# Whole-project Flutter quality gate: analyzer + unit tests.
# Used by the pre-commit hook (`.pre-commit-config.yaml`) and by CI; can also
# be run manually from the repo root: `tool/check.sh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Locate the Flutter SDK binary (FLUTTER_ROOT > PATH > workspace copy).
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  FLUTTER_BIN="$FLUTTER_ROOT/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(command -v flutter)"
elif [[ -x "$HOME/Documents/Eink/flutter_sdk/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/Documents/Eink/flutter_sdk/bin/flutter"
else
  echo "error: Flutter SDK not found — set FLUTTER_ROOT or add flutter to PATH" >&2
  exit 1
fi

echo "==> flutter analyze"
"$FLUTTER_BIN" analyze

echo "==> flutter test"
"$FLUTTER_BIN" test

echo "✔ analyze + test OK"
