/// Controls the Waze-Mod-style floating speed-limit / camera widget
/// (`flutter_overlay_window`). The widget runs in its own Flutter engine
/// ([overlayMain]) and is fully self-contained — it reads its own GPS and the
/// bundled offline speed-limit + camera layers, so it keeps working while the
/// user runs any other navigation app in the foreground.
library;

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// True when the system "display over other apps" permission is granted.
Future<bool> overlayPermissionGranted() =>
    FlutterOverlayWindow.isPermissionGranted();

/// Ask for the overlay permission (opens the system overlay settings page).
/// The plugin returns `bool?` on some platforms — treat null as denied.
Future<bool> requestOverlayPermission() async =>
    await FlutterOverlayWindow.requestPermission() ?? false;

/// Show the floating widget: draggable, auto-sticks to the right edge.
Future<void> startOverlay() async {
  if (!await overlayPermissionGranted()) {
    final ok = await requestOverlayPermission();
    if (!ok) return;
  }
  await FlutterOverlayWindow.showOverlay(
    overlayTitle: 'NavBridge',
    overlayContent: 'Widget tốc độ / giới hạn',
    enableDrag: true,
    positionGravity: PositionGravity.right,
    alignment: OverlayAlignment.topRight,
  );
}

/// Remove the floating widget.
Future<void> stopOverlay() => FlutterOverlayWindow.closeOverlay();
