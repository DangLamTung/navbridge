#!/usr/bin/env bash
# ==============================================================================
# Fetch the LOCAL-ONLY asset packs the app bundles but git does not track.
#
# Why this exists: these packs are not in git because they are large, binary,
# regenerable, and (for the data packs) policy-sensitive. A clean checkout
# therefore has STUBS, and a release build from stubs would ship an empty
# posted-limit layer and no voice packs. `tool/stub_assets.sh` documents this:
# "Releases need the real files (build locally, or fetch the packs in the
# release workflow)."  This is that fetch.
#
# It is a NO-OP for any pack already present, so a build machine that has the
# real files is never touched.
#
# Usage:
#   tool/fetch_assets.sh                 # default tag: voice-packs-latest
#   ASSETS_TAG=<tag> tool/fetch_assets.sh
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${ASSETS_TAG:-voice-packs-latest}"
REPO="${GITHUB_REPOSITORY:-DangLamTung/navbridge}"

# pack archive name -> destination directory
PACKS=(
  "voice_vn_hanoi_quyphai"
  "voice_vn_gcp"
  "voice_vn_gemini"
)

missing=()
for p in "${PACKS[@]}"; do
  # `-s` catches the empty-file stub that stub_assets.sh writes.
  if [ -s "assets/audio/$p/MANIFEST.json" ]; then
    echo "have:  assets/audio/$p/"
  else
    missing+=("$p")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "all voice packs present — nothing to fetch"
  exit 0
fi

echo "fetching ${#missing[@]} voice pack(s) from $REPO tag '$TAG'..."
for p in "${missing[@]}"; do
  url="https://github.com/$REPO/releases/download/$TAG/$p.tar.gz"
  echo "  -> $url"
  mkdir -p "assets/audio/$p"
  if ! curl -fsSL "$url" | tar -xzf - -C "assets/audio/$p" --strip-components=1; then
    echo "ERROR: could not fetch $p. A release build from stubs would ship no" >&2
    echo "       voice for speed-limit announcements. Bailing out." >&2
    exit 1
  fi
  test -s "assets/audio/$p/MANIFEST.json" ||
    { echo "ERROR: $p unpacked but MANIFEST.json is missing/empty" >&2; exit 1; }
  echo "  ok: assets/audio/$p/"
done

echo "done."
