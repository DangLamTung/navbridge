#!/usr/bin/env bash
# Create EMPTY placeholders for the local-only data packs listed in pubspec.yaml.
#
# Why this exists: the big packs are NOT in git —
#   * assets/offline_map/waze_segments.bin  (built from the DATMAP/Waze pipeline,
#     see docs/waze-data-pipeline.md)
#   * assets/audio/**                       (recorded / extracted voice clips)
# — and a missing entry makes the asset-bundle build FAIL, so `flutter pub get`,
# `flutter test` and `flutter build` cannot run on a clean checkout (CI).
#
# CI only needs the paths to EXIST: the data-dependent tests skip themselves when
# a pack is empty (`speedLimitsPopulated` in test/offline_speed_limits_test.dart),
# and every real data check reads files that ARE tracked. Tests never need the
# contents of these two packs.
#
# Do NOT use this before a RELEASE build: a stubbed APK would ship an empty
# posted-limit layer and no voice packs. Releases need the real files (build
# locally, or fetch the packs in the release workflow).
#
# Usage: tool/stub_assets.sh
set -euo pipefail

cd "$(dirname "$0")/.."

stubbed=0
while read -r entry; do
  [[ -z "$entry" ]] && continue
  if [[ -e "$entry" ]]; then
    continue # the real pack is here — never touch it
  fi
  if [[ "$entry" == */ ]]; then
    mkdir -p "$entry"
    echo "stub: dir  $entry"
  else
    mkdir -p "$(dirname "$entry")"
    : >"$entry"
    echo "stub: file $entry"
  fi
  stubbed=$((stubbed + 1))
done < <(grep -E '^[[:space:]]+- assets/' pubspec.yaml |
  sed 's/^[[:space:]]*-[[:space:]]*//')

if [[ "$stubbed" == 0 ]]; then
  echo "no missing asset entries — nothing stubbed"
fi
