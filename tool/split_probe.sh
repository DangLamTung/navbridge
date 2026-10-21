#!/usr/bin/env bash
# Why is THIS app not offered in ZUI's split chooser, while another third-party
# app on the same tablet is?
#
# Target: Lenovo TB331FC — ZUI 15.1 on **Android 13 / API 33**.
#
# Background, so this is not re-litigated (see
# docs/experiments_route-import-waze-split.md, §3):
#   * the manifest already declares everything Android's multi-window guide
#     asks for, verified in the shipped APK with `aapt2 dump xmltree`;
#   * the framework agrees we are fine — `supportsMultiWindow=true`,
#     `resizeMode=RESIZE_MODE_RESIZEABLE`, `isResizeable=true`;
#   * freeform (windowing mode 5) can be forced from the shell and renders;
#   * yet ZUI greys out Floating Window / Split Screen in its own window menu
#     and omits the app from the split chooser, while `com.driving.hud.usbcamera`
#     on the same device gets both.
# => the gate is inside ZUI (SystemUI/launcher), not in Android.
#
# Nobody has established WHICH input ZUI reads to build that list. This script
# records every candidate for our app AND for the app that works, so the two can
# be diffed, plus the ROM's own freeform log lines.
#
#   ADB_SERIAL=<serial> tool/split_probe.sh [apk]
#
# Evidence lands in /tmp/split_probe_<hhmmss>/ ; one step still needs eyes on
# the tablet (printed at the end).
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/Users/tungdl/Library/Android/sdk/platform-tools:$PATH"

ADB=(adb)
if [[ -n "${ADB_SERIAL:-}" ]]; then
  ADB=(adb -s "$ADB_SERIAL")
  echo "target device: $ADB_SERIAL"
fi

APP="com.navbridge.app"
CAM="${HUD_CAMERA_PACKAGE:-com.driving.hud.usbcamera}"
OUT="/tmp/split_probe_$(date +%H%M%S)"
mkdir -p "$OUT"
echo "evidence -> $OUT"

"${ADB[@]}" wait-for-device

# ---------------------------------------------------------------- device facts
{
  echo "## device"
  for p in ro.product.model ro.build.version.release ro.build.version.sdk \
           ro.build.characteristics ro.build.display.id \
           ro.config.lgsi.ovfreeform_enabled persist.ov.freeform.dcv_menu_show \
           ro.build.version.security_patch; do
    printf '%-40s %s\n' "$p" "$("${ADB[@]}" shell getprop "$p" 2>/dev/null | tr -d '\r')"
  done
  echo
  echo "## display (dp = px * 160 / density; smallestWidth >= 600dp = tablet)"
  "${ADB[@]}" shell wm size | tr -d '\r'
  "${ADB[@]}" shell wm density | tr -d '\r'
} | tee "$OUT/device.txt"

# ------------------------------------------------------------------- install
APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
if [[ -f "$APK" ]]; then
  echo "installing $APK"
  ADB_SERIAL="${ADB_SERIAL:-}" tool/install.sh "$APK" 2>&1 | tee "$OUT/install.log"
else
  echo "no APK at $APK — probing the build already on the device"
  "${ADB[@]}" shell am force-stop "$APP" >/dev/null 2>&1 || true
  # NEVER `am start -n pkg/.Activity`: a bare component intent leaves the task's
  # BASE intent without action/category, and because MainActivity is
  # launchMode=singleTop every later launch re-fronts that poisoned task.
  "${ADB[@]}" shell am start -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER -n "$APP/.MainActivity" >/dev/null 2>&1
fi
sleep 3

# ------------------------------------------------- package facts: us vs them
pkg_facts() {
  local pkg="$1"
  echo "=== $pkg ==="
  "${ADB[@]}" shell dumpsys package "$pkg" 2>/dev/null | tr -d '\r' | grep -m1 -E \
    "installerPackageName|targetSdk=|versionName=|flags=\[|privateFlags=\[|pkgFlags" || echo "  (not installed)"
  "${ADB[@]}" shell dumpsys package "$pkg" 2>/dev/null | tr -d '\r' | grep -A2 "signatures" | head -4
  echo
}
{
  echo "## package facts — the app that FAILS vs the app that WORKS"
  pkg_facts "$APP"
  pkg_facts "$CAM"
  echo "## every third-party (sideloaded or Play) package: installer + targetSdk"
  echo "   ^ feed the control experiment: pick any of these and check whether"
  echo "     ZUI's split chooser lists it. If NO sideloaded app is ever listed,"
  echo "     the gate is installer identity, not our code."
  for p in $("${ADB[@]}" shell pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://'); do
    inst=$("${ADB[@]}" shell dumpsys package "$p" 2>/dev/null | tr -d '\r' | grep -m1 installerPackageName | awk -F= '{print $2}')
    tsdk=$("${ADB[@]}" shell dumpsys package "$p" 2>/dev/null | tr -d '\r' | grep -m1 -o 'targetSdk=[0-9]*' | cut -d= -f2)
    printf '%-45s installer=%-28s targetSdk=%s\n' "$p" "${inst:-<none>}" "${tsdk:-?}"
  done
} | tee "$OUT/packages.txt"

# ------------------------------------------------------- task / window state
{
  echo "## running tasks (a real split = TWO SIBLING root tasks: mode=3 + mode=4;"
  echo "##  one task containing both apps is a degenerate stack that still"
  echo "##  renders fullscreen — never trust it, always screenshot)"
  "${ADB[@]}" shell dumpsys activity activities 2>/dev/null | tr -d '\r' \
    | grep -E "Task\{|windowingMode=|mResizeMode|supportsMultiWindow|realActivity" | head -40
} | tee "$OUT/tasks.txt"

# ------------------------------------------------------------ ROM's own logs
{
  echo "## ZUI freeform / split decisions in the log"
  "${ADB[@]}" logcat -d -v brief 2>/dev/null | tr -d '\r' \
    | grep -iE "freeform|screensplit|blackListNotResize|isLauncherApp|MultiGroupRecentTasks|split" \
    | tail -60
} | tee "$OUT/logcat.txt"

"${ADB[@]}" exec-out screencap -p > "$OUT/screen.png" 2>/dev/null || true

cat <<EOF

=== evidence written to $OUT ===
  device.txt    model / API / freeform props / display
  packages.txt  our facts vs the working camera app, + every third-party app
  tasks.txt     root tasks, windowing modes
  logcat.txt    ZUI's freeform/split decisions
  screen.png    current screen

ONE MANUAL STEP (only eyes on the tablet can do it):
  1. Recents -> long-press NavBridge's icon -> the ROM window menu.
     Are "Floating Window" and "Split Screen" ENABLED now?
  2. Same for the camera app ($CAM) — it is the known-good control.
  3. Open ZUI's split chooser and note whether NavBridge is listed, and whether
     ANY app from the installer=<none> rows in packages.txt is listed.
Screenshot each state; then re-run this script so the log catches the
menu-open decision.
EOF
