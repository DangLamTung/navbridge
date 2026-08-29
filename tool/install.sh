#!/bin/bash
# Resilient APK install — waits for the phone, picks the matching ABI APK,
# and retries (the phone drops off adb constantly).
export PATH="/Users/tungdl/Library/Android/sdk/platform-tools:$PATH"
OUT="$HOME/Documents/Eink/navbridge/build/app/outputs/flutter-apk"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  echo "=== attempt $attempt: waiting for device ==="
  adb wait-for-device
  if ! adb get-state 2>/dev/null | grep -q device; then
    echo "no device; retrying"
    adb reconnect >/dev/null 2>&1
    continue
  fi
  ABI=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
  case "$ABI" in
    arm64-v8a) APK="$OUT/app-arm64-v8a-release.apk" ;;
    armeabi-v7a|armeabi) APK="$OUT/app-armeabi-v7a-release.apk" ;;
    x86_64) APK="$OUT/app-x86_64-release.apk" ;;
    *) APK="$OUT/app-release.apk" ;;
  esac
  echo "ABI=$ABI -> $APK"
  if adb install -r "$APK"; then
    echo "INSTALL OK"
    adb shell am force-stop com.navbridge.app 2>/dev/null
    adb shell monkey -p com.navbridge.app -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    echo "LAUNCHED"
    exit 0
  fi
  echo "install failed; retrying"
done
echo "GAVE UP after 10 attempts"
exit 1
