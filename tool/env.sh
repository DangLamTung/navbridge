#!/usr/bin/env bash
# Load navbridge/.env (gitignored, local-only) and export its keys as
# --dart-define flags in the $DART_DEFINES array, so flutter build/run picks
# up the Vietmap keys without them ever living in source control.
#
# Usage (from the navbridge root):
#   source tool/env.sh
#   flutter run "${DART_DEFINES[@]}"
#
# Missing .env is non-fatal: you just get a warning and no flags (the app
# then builds in the keyless/OSM fallback mode).
set -u

ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"

DART_DEFINES=()

if [[ ! -f "$ENV_FILE" ]]; then
  echo "tool/env.sh: WARNING: $ENV_FILE not found." >&2
  echo "  Copy .env.example to .env and fill in your Vietmap keys." >&2
else
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# The user's .env commonly names the Google key GOOGLEMAPS_API_KEY; map it to
# the specific flags the app reads (Google Places + Geocoding) so search works
# with a single key. The specific *_KEY entries win if also present.
if [[ -z "${GOOGLE_PLACES_KEY:-}" && -n "${GOOGLEMAPS_API_KEY:-}" ]]; then
  GOOGLE_PLACES_KEY="$GOOGLEMAPS_API_KEY"
fi
if [[ -z "${GOOGLE_GEOCODE_KEY:-}" && -n "${GOOGLEMAPS_API_KEY:-}" ]]; then
  GOOGLE_GEOCODE_KEY="$GOOGLEMAPS_API_KEY"
fi

for key in VIETMAP_API_KEY VIETMAP_TILE_KEY GOOGLE_GEOCODE_KEY \
  GOOGLE_PLACES_KEY WINDY_API_KEY ACCUWEATHER_API_KEY GRAPH_URL \
  DEEPSEEK_API_KEY GEMINI_API_KEY TAVILY_API_KEY; do
  val="${!key:-}"
  if [[ -n "$val" ]]; then
    DART_DEFINES+=("--dart-define=$key=$val")
  fi
done
