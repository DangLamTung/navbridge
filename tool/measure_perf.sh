#!/usr/bin/env bash
# Measure NavBridge CPU + GPU usage during navigation on a connected device.
#
# Usage:
#   ./tool/measure_perf.sh [duration_seconds]      (default 30)
#   ADB_SERIAL=11046644BW000992 ./tool/measure_perf.sh
#
# Requirements:
#   - adb (default /Users/tungdl/Documents/Eink/platform-tools/adb)
#   - the phone connected + app installed
#   - Start navigating (an active route) in the app, THEN run this script.
#     It samples the app's CPU while the route is live and dumps the GPU
#     frame histogram from the last ~5s of rendering.
set -euo pipefail

ADB="${ADB:-/Users/tungdl/Documents/Eink/platform-tools/adb}"
PKG="com.navbridge.app"
DUR="${1:-30}"
SERIAL="${ADB_SERIAL:-}"

if [[ -n "$SERIAL" ]]; then
  ADB_ARGS=(-s "$SERIAL")
else
  ADB_ARGS=()
fi

adb_sh() {
  if [[ -n "$SERIAL" ]]; then
    "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" "$@"
  fi
}

adb_sh get-state >/dev/null 2>&1 || {
  echo "ERROR: no device connected. Check USB / run: $ADB devices"
  exit 1
}
adb_sh shell pidof "$PKG" >/dev/null 2>&1 || {
  echo "ERROR: $PKG is not running. Start navigating first."
  exit 1
}

echo "== NavBridge perf — ${DUR}s of CPU sampling =="
echo "Route must be ACTIVE now (map moving, ETA counting down)."
echo ""

# --- CPU: sample the app process CPU% every second for DUR seconds ---
PID="$(adb_sh shell pidof "$PKG" | tr -d '\r' | awk '{print $1}')"
: > /tmp/nb_cpu.txt
for i in $(seq 1 "$DUR"); do
  # toybox `top`: col 9 = %CPU (of ONE core), col 6 = RES in KB
  adb_sh shell top -b -n 1 -d 0.5 2>/dev/null \
    | grep -w "$PID" | awk '{print $9, $6}' >> /tmp/nb_cpu.txt || true
done

n=$(grep -c . /tmp/nb_cpu.txt || true)
if [[ "$n" -eq 0 ]]; then
  echo "no CPU samples captured (process not visible to top)."
else
  awk -v n="$n" '
    function kb(x) {          # RES column has a K/M/G suffix
      if (x ~ /[Gg]$/) return substr(x,1,length(x)-1)*1024*1024
      if (x ~ /[Mm]$/) return substr(x,1,length(x)-1)*1024
      if (x ~ /[Kk]$/) return substr(x,1,length(x)-1)
      return x
    }
    { s+=$1; if ($1>m) m=$1; rs+=kb($2) }
    END {
      printf "CPU  -> avg %.1f%%   max %.1f%%   (%d samples, %% of ONE core)\n", s/n, m, n
      printf "RAM  -> avg %.0f MB RSS\n", rs/n/1024
    }' /tmp/nb_cpu.txt
fi

echo ""
echo "--- recent per-process CPU (dumpsys cpuinfo) ---"
adb_sh shell dumpsys cpuinfo 2>/dev/null | grep -i "$PKG" || true

# --- GPU: frame rendering cost (map UI) ---
echo ""
echo "--- GPU frame stats (dumpsys gfxinfo) ---"
adb_sh shell dumpsys gfxinfo "$PKG" 2>/dev/null \
  | grep -E "Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile" || true
echo ""
echo "Frame time budget: 16.6 ms/frame @60fps (higher %tile = heavier GPU use)."
echo "Janky%% = frames over budget; big map re-renders / style reloads push it up."
