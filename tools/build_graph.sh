#!/usr/bin/env bash
# Build a NavBridge offline routing graph (.ghz) from an OSM PBF.
#
#   ./build_graph.sh <in.osm.pbf> <out-name>
#
# Produces <out-name>.ghz next to the pbf. The graph uses the same car
# profile as the app (see GraphHopperRouting.carProfile).
set -euo pipefail

PBF="$1"
NAME="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$(dirname "$PBF")" && pwd)/${NAME}"
JAVA="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}/bin/java"

# Classpath: every non-sources jar already fetched by Gradle, excluding
# GraphHopper 8.x/9.x/10.x (we build/run with 7.0 — the Android-compatible line).
CP="$(find "$HOME/.gradle/caches/modules-2" -name '*.jar' ! -name '*-sources.jar' \
      ! -name '*-javadoc.jar' 2>/dev/null | grep -vE 'graphhopper.*/(8\.|9\.|10\.)' | tr '\n' ':')"

echo "Compiling + importing $PBF -> $OUT  (can take a while for large regions)..."
"$JAVA" -Xmx14g -cp "$CP" --source 17 "$DIR/BuildGraph.java" "$PBF" "$OUT"

echo "Zipping -> ${OUT}.ghz"
rm -f "${OUT}.ghz"
# Zip the graph CONTENTS at the root so on-device extraction lands the graph
# files directly in the target folder.
(cd "$OUT" && zip -qr "$(dirname "$OUT")/${NAME}.ghz" .)
echo "DONE: ${OUT}.ghz"
