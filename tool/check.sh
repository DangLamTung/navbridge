#!/usr/bin/env bash
# Whole-project Flutter quality gate: analyzer + UNIT tests + FUNCTION tests.
# Used by the pre-commit hook (`.pre-commit-config.yaml`) and by CI; can also
# be run manually from the repo root: `tool/check.sh`.
#
# TWO test lines, on purpose (user, 2026-09-28): a unit test is deterministic
# and self-contained, a function test drives the app against the SHIPPED packs
# and recorded trips. They are kept apart so a pack-only failure cannot be read
# as a logic regression, and so a change to pure logic can be verified without
# waiting on 28 MB of data:
#
#   test/unit/**   no pack loader, no fixture file, no real trip
#   test/func/**   loads a pack / fixture / recorded trip, and SKIPS when the
#                  packs are stubbed  (func/{trip,resident,signs,limits,packs})
#
# The classification is mechanical, not a matter of taste — run
# `python3 tool/classify_tests.py --list` to see it and why each file landed
# where it did.
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

# A file named `_*_test.dart` inside test/ is an EXPERIMENT (a sweep, a probe —
# someone's measurement session), not a test. Two of them were left in the trip
# dir and the gate ran them: the sweep rewrote docs/hn_sg_limit_sweep.json on
# every run. They belong in tool/experiments/, which you run by path:
#   flutter test tool/experiments/_limit_sweep_test.dart
leftovers="$(find test -name '_*_test.dart' -print)"
if [[ -n "$leftovers" ]]; then
  echo "error: experiment file(s) inside test/ — move to tool/experiments/:" >&2
  echo "$leftovers" >&2
  exit 1
fi

# A test file loose in test/ (or in any directory other than unit/ and func/)
# would be run by NEITHER line below, so the gate would silently stop covering
# it. That is the failure mode the split introduces; guard against it.
strays="$(find test -name '*_test.dart' \
  -not -path 'test/unit/*' -not -path 'test/func/*' -print)"
if [[ -n "$strays" ]]; then
  echo "error: test file(s) outside test/unit and test/func — the split would" >&2
  echo "       leave them uncovered (see tool/classify_tests.py):" >&2
  echo "$strays" >&2
  exit 1
fi

unit_files="$(find test/unit -name '*_test.dart' | wc -l | tr -d ' ')"
func_files="$(find test/func -name '*_test.dart' | wc -l | tr -d ' ')"

# FUNCTION first: it is the line that fails for data reasons (a pack missing,
# a fixture changed), and those failures are the more informative ones to see
# before the unit line reports its own summary.
echo "==> FUNCTION tests ($func_files files: trip, long trip, in/out resident, signs)"
"$FLUTTER_BIN" test test/func

echo "==> UNIT tests ($unit_files files)"
"$FLUTTER_BIN" test test/unit

echo "✔ analyze + FUNCTION tests OK + UNIT tests OK"
