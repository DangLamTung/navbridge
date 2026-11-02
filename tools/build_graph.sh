#!/usr/bin/env bash
# Build a NavBridge offline routing graph (.ghz) from an OSM PBF.
#
#   ./build_graph.sh <in.osm.pbf> <out-name>
#
# Produces <out-name>.ghz next to the pbf. The graph carries BOTH the car and
# motorcycle profiles (see GraphHopperRouting.carProfile/motorcycleProfile);
# the app picks one per route request.
set -euo pipefail

PBF="$1"
NAME="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$(dirname "$PBF")" && pwd)/${NAME}"
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
  JAVA="$JAVA_HOME/bin/java"
elif [[ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
  JAVA="/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"
elif command -v java >/dev/null 2>&1; then
  JAVA="$(command -v java)"
else
  echo "Error: Java 17+ not found. Set JAVA_HOME or install Android Studio." >&2
  exit 1
fi

# Classpath: jars resolved for this build when GH_CP_DIR is set (CI, see
# tools/graph-builder/pom.xml), else every non-sources jar already fetched by
# Gradle, excluding GraphHopper 8.x/9.x/10.x (we build/run with 7.0 — the
# Android-compatible line).
#
# `grep` exits 1 on an empty match and `set -o pipefail` would then kill the
# script with NO message — which is exactly how this step died on CI (a fresh
# runner has no ~/.gradle). Collect into a variable and check it instead.
CP=""
if [[ -n "${GH_CP_DIR:-}" && -d "${GH_CP_DIR}" ]]; then
  CP="$(find "${GH_CP_DIR}" -name '*.jar' 2>/dev/null | tr '\n' ':')"
  echo "Classpath: ${GH_CP_DIR} (GH_CP_DIR)"
fi
if [[ -z "$CP" ]]; then
  CP="$(find "$HOME/.gradle/caches/modules-2" -name '*.jar' \
        ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null \
        | { grep -vE 'graphhopper.*/(8\.|9\.|10\.)' || true; } | tr '\n' ':')"
  [[ -n "$CP" ]] && echo "Classpath: ~/.gradle/caches (local Gradle build)"
fi
if [[ -z "$CP" ]]; then
  echo "Error: no GraphHopper jars found — cannot compile tools/BuildGraph.java." >&2
  echo "  Locally: any APK build populates ~/.gradle/caches/modules-2." >&2
  echo "  Elsewhere: mvn -q -B -f tools/graph-builder/pom.xml \\" >&2
  echo "               dependency:copy-dependencies -DincludeScope=runtime \\" >&2
  echo "               -DoutputDirectory=\$PWD/tools/data/gh-jars" >&2
  echo "             then set GH_CP_DIR=\$PWD/tools/data/gh-jars." >&2
  exit 1
fi

echo "Compiling + importing $PBF -> $OUT  (can take a while for large regions)..."
"$JAVA" -Xmx${GRAPH_MEM:-12g} -cp "$CP" --source 17 "$DIR/BuildGraph.java" "$PBF" "$OUT"

echo "Zipping -> ${OUT}.ghz"
rm -f "${OUT}.ghz"
# Zip the graph CONTENTS at the root so on-device extraction lands the graph
# files directly in the target folder.
(cd "$OUT" && zip -qr "$(dirname "$OUT")/${NAME}.ghz" .)
echo "DONE: ${OUT}.ghz"
