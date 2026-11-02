#!/usr/bin/env bash
# =============================================================================
# auto_create_graph.sh: Download OSM data and automatically build GraphHopper graph (.ghz)
#
# Usage:
#   tools/auto_create_graph.sh [region|url] [--push]
#
# Examples:
#   tools/auto_create_graph.sh                 # Download Vietnam extract & build
#   tools/auto_create_graph.sh --push          # Build & push to connected phone
#   tools/auto_create_graph.sh saigon          # Build Ho Chi Minh City extract
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
DATA_DIR="$ROOT/tools/data"
mkdir -p "$DATA_DIR"

REGION="vietnam"
DO_PUSH=false

for arg in "$@"; do
  case "$arg" in
    --push|-p)
      DO_PUSH=true
      ;;
    vietnam|vn)
      REGION="vietnam"
      ;;
    saigon|hcm)
      REGION="saigon"
      ;;
    hanoi|hn)
      REGION="hanoi"
      ;;
    http*|*.osm.pbf)
      REGION="$arg"
      ;;
    *)
      REGION="$arg"
      ;;
  esac
done

# Resolve PBF URL and filename.
#
# The city extracts come from the bbbike mirror, which intermittently answers
# 404 for a city (it did for HoChiMinhCity on 2026-11-01, which killed the
# monthly offline-data job). PBF_FALLBACK_* is the country extract we drop to
# when the city mirror is unavailable, so the build still produces a graph.
COUNTRY_PBF_URL="https://download.geofabrik.de/asia/vietnam-latest.osm.pbf"
COUNTRY_PBF_FILE="$DATA_DIR/vietnam-latest.osm.pbf"
if [[ "$REGION" == "vietnam" ]]; then
  PBF_URL="$COUNTRY_PBF_URL"
  PBF_FILE="$COUNTRY_PBF_FILE"
  GRAPH_NAME="routing_graph"
elif [[ "$REGION" == "saigon" ]]; then
  PBF_URL="https://download.bbbike.org/osm/bbbike/HoChiMinhCity/HoChiMinhCity.osm.pbf"
  PBF_FILE="$DATA_DIR/saigon-latest.osm.pbf"
  GRAPH_NAME="routing_graph"
  PBF_FALLBACK_URL="$COUNTRY_PBF_URL"
  PBF_FALLBACK_FILE="$COUNTRY_PBF_FILE"
elif [[ "$REGION" == "hanoi" ]]; then
  PBF_URL="https://download.bbbike.org/osm/bbbike/Hanoi/Hanoi.osm.pbf"
  PBF_FILE="$DATA_DIR/hanoi-latest.osm.pbf"
  GRAPH_NAME="routing_graph"
  PBF_FALLBACK_URL="$COUNTRY_PBF_URL"
  PBF_FALLBACK_FILE="$COUNTRY_PBF_FILE"
elif [[ "$REGION" =~ ^https?:// ]]; then
  PBF_URL="$REGION"
  PBF_FILE="$DATA_DIR/custom-latest.osm.pbf"
  GRAPH_NAME="routing_graph"
elif [[ -f "$REGION" ]]; then
  PBF_URL=""
  PBF_FILE="$(cd "$(dirname "$REGION")" && pwd)/$(basename "$REGION")"
  GRAPH_NAME="routing_graph"
else
  echo "Error: Unknown region or file: $REGION" >&2
  exit 1
fi

echo "========================================================"
echo " NavBridge GraphHopper Auto Creator"
echo " Region/Source: $REGION"
echo " Target PBF:    $PBF_FILE"
echo " Output Graph:  $DATA_DIR/${GRAPH_NAME}.ghz"
echo "========================================================"

# Step 1: Download PBF if missing or URL given
#
# A devolved 404 leaves a partial/HTML file behind, so the failed attempt is
# removed before falling back — `curl -C -` would otherwise resume from it.
fetch_pbf() {
  local url="$1" out="$2"
  echo "    $url"
  if curl -C - -L --fail --retry 2 --retry-delay 5 --progress-bar \
      -o "$out" "$url"; then
    return 0
  fi
  rm -f "$out"
  return 1
}

if [[ -n "${PBF_URL:-}" ]]; then
  echo ""
  echo "==> [1/3] Downloading OpenStreetMap extract from:"
  if ! fetch_pbf "$PBF_URL" "$PBF_FILE"; then
    if [[ -n "${PBF_FALLBACK_URL:-}" ]]; then
      echo ""
      echo "!! The city extract is unavailable (mirror moved or 404)."
      echo "!! Falling back to the country extract:"
      PBF_URL="$PBF_FALLBACK_URL"
      PBF_FILE="$PBF_FALLBACK_FILE"
      if ! fetch_pbf "$PBF_URL" "$PBF_FILE"; then
        echo "Error: every extract source failed (last: $PBF_URL)" >&2
        exit 1
      fi
    else
      echo "Error: download failed: $PBF_URL" >&2
      exit 1
    fi
  fi
else
  echo "==> [1/3] Using local PBF file: $PBF_FILE"
fi

if [[ ! -s "$PBF_FILE" ]]; then
  echo "Error: PBF file is missing or empty: $PBF_FILE" >&2
  exit 1
fi

# Step 2: Build GraphHopper graph
echo ""
echo "==> [2/3] Building GraphHopper car graph with tools/build_graph.sh..."
bash "$DIR/build_graph.sh" "$PBF_FILE" "$GRAPH_NAME"

GHZ_FILE="$(dirname "$PBF_FILE")/${GRAPH_NAME}.ghz"
if [[ ! -f "$GHZ_FILE" ]]; then
  echo "Error: Failed to produce $GHZ_FILE" >&2
  exit 1
fi

GHZ_SIZE=$(du -h "$GHZ_FILE" | cut -f1)
echo "SUCCESS: Created $GHZ_FILE ($GHZ_SIZE)"

# Step 3: Push to connected phone if requested or available
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
if [[ -x "$ADB" ]]; then
  DEVICE="$("$ADB" devices | grep -E 'device$' | head -n 1 | cut -f1 || true)"
  if [[ -n "$DEVICE" ]]; then
    if [[ "$DO_PUSH" == "true" ]]; then
      echo ""
      echo "==> [3/3] Connected device found: $DEVICE. Pushing to phone..."
      "$ADB" push "$GHZ_FILE" /sdcard/Download/routing_graph.ghz
      echo "Pushed to device: /sdcard/Download/routing_graph.ghz"
      echo "NavBridge will automatically load this graph on launch or via the Offline screen."
    else
      echo ""
      echo "Tip: Connected Android device detected ($DEVICE)."
      echo "Run with --push to automatically install the graph to the device:"
      echo "  $ADB push \"$GHZ_FILE\" /sdcard/Download/routing_graph.ghz"
    fi
  fi
fi

echo ""
echo "All done! Graph is ready at: $GHZ_FILE"
