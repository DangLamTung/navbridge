#!/bin/bash
export PATH="/Users/tungdl/Library/Android/sdk/platform-tools:$PATH"
OUT="$HOME/Documents/Eink/navbridge/build/app/outputs/flutter-apk"

ADB=(adb)
if [[ -n "${ADB_SERIAL:-}" ]]; then
  ADB=(adb -s "$ADB_SERIAL")
  echo "target device: $ADB_SERIAL"
fi

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  echo "=== attempt $attempt: waiting for device ==="
  "${ADB[@]}" wait-for-device
  if ! "${ADB[@]}" get-state 2>/dev/null | grep -q device; then
    echo "no device; retrying"
    "${ADB[@]}" reconnect >/dev/null 2>&1
    continue
  fi
  ABI=$("${ADB[@]}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
  if [[ -n "${1:-}" && -f "$1" ]]; then
    APK="$1"
  else
    case "$ABI" in
      arm64-v8a) APK="$OUT/app-arm64-v8a-release.apk" ;;
      armeabi-v7a|armeabi) APK="$OUT/app-armeabi-v7a-release.apk" ;;
      x86_64) APK="$OUT/app-x86_64-release.apk" ;;
      *) APK="$OUT/app-release.apk" ;;
    esac
    if [[ ! -f "$APK" && -f "$OUT/app-release.apk" ]]; then
      APK="$OUT/app-release.apk"
    fi
  fi
  echo "ABI=$ABI -> $APK"
  if "${ADB[@]}" install -r -d "$APK"; then
    echo "INSTALL OK"
    "${ADB[@]}" shell am force-stop com.navbridge.app 2>/dev/null
    # Launch with the REAL launcher intent (ACTION_MAIN + CATEGORY_LAUNCHER),
    # NOT `am start -n pkg/.Activity` and NOT monkey.
    #
    # A bare component intent creates a task whose BASE intent carries no
    # action/category. Lenovo ZUI's freeform code classifies such a task with
    # `isLauncherApp == false` (see OVFeatureUtils / the ovfreeform service) and
    # then greys out "Floating Window" and "Split Screen" in the window menu.
    # Because MainActivity is launchMode=singleTop, every later launch just
    # re-fronts that same poisoned task, so the app stays un-floatable until the
    # task is cleared — which is why the app looked "not splittable" while the
    # HUD camera app (started from the launcher, correct base intent) was fine.
    "${ADB[@]}" shell am start -a android.intent.action.MAIN \
      -c android.intent.category.LAUNCHER \
      -n com.navbridge.app/.MainActivity >/dev/null 2>&1
    echo "LAUNCHED"
    exit 0
  fi
  echo "install failed; retrying"
done
echo "GAVE UP after 10 attempts"
exit 1
