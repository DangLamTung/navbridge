/// Controls the Waze-Mod-style floating speed-limit / camera widget
/// (`flutter_overlay_window`). The widget runs in its own Flutter engine
/// ([overlayMain]) and is fully self-contained — it reads its own GPS and the
/// bundled offline speed-limit + camera layers, so it keeps working while the
/// user runs any other navigation app in the foreground.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'package:navbridge/services/overlay_visibility.dart';

/// True when the system "display over other apps" permission is granted.
Future<bool> overlayPermissionGranted() =>
    FlutterOverlayWindow.isPermissionGranted();

/// Ask for the overlay permission (opens the system overlay settings page).
/// The plugin returns `bool?` on some platforms — treat null as denied.
Future<bool> requestOverlayPermission() async =>
    await FlutterOverlayWindow.requestPermission() ?? false;

/// One selectable floating-widget layout (picked on the layout page).
class OverlayLayoutDef {
  final String id;
  final String label;
  final String desc;
  final double widthDp;
  final double heightDp;
  const OverlayLayoutDef(
    this.id,
    this.label,
    this.desc,
    this.widthDp,
    this.heightDp,
  );
}

/// The layouts offered in Settings → "Tùy chọn bong bóng nổi":
/// "Nằm ngang" and "Nằm dọc".
// IMPORTANT: each window size here must EXACTLY match the widget it renders
// (the dial is 168×168, the horizontal card 216×76, the vertical card
// 82×260). If the window is larger than the content, the leftover strip is a
// TRANSPARENT overlay that still captures touches — which blocked the
// keyboard/touch on the app underneath. Window == content → nothing captures
// outside the visible bubble.
const List<OverlayLayoutDef> kOverlayLayouts = [
  OverlayLayoutDef(
    'dial',
    'Đồng hồ tốc độ',
    'Mặt đồng hồ kim + biển giới hạn ở góc phải (kiểu đồng hồ cổ điển)',
    168,
    168,
  ),
  OverlayLayoutDef(
    'horizontal',
    'Nằm ngang',
    'Bố cục thanh ngang: Tốc độ · Biển giới hạn · Camera trên một hàng',
    216,
    76,
  ),
  OverlayLayoutDef(
    'vertical',
    'Nằm dọc',
    'Bố cục dải dọc: Mũi tên rẽ + Biển giới hạn + Tốc độ + Camera',
    82,
    260,
  ),
];

/// The window size (dp) for a layout id and scale multiplier.
(double, double) overlaySizeDpFor(String id, {double? scale}) {
  final s = (scale ?? overlayScale).clamp(0.8, 2.0);
  final mappedId = switch (id) {
    'dial' || 'speedometer' => 'dial',
    'horizontal' || 'pill' => 'horizontal',
    _ => 'vertical',
  };
  for (final l in kOverlayLayouts) {
    if (l.id == mappedId) return (l.widthDp * s, l.heightDp * s);
  }
  return (82 * s, 260 * s);
}

/// Resize an ALREADY-SHOWN floating widget to a layout's size (physical px).
/// No-op when the overlay isn't running. Stays draggable.
Future<void> resizeOverlayForLayout(String id, {double? scale}) async {
  final (w, h) = overlaySizeDpFor(id, scale: scale);
  final views = WidgetsBinding.instance.platformDispatcher.views;
  final dpr = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  try {
    await FlutterOverlayWindow.resizeOverlay(
      (w * dpr).round(),
      (h * dpr).round(),
      true, // keep dragging enabled
    );
  } catch (_) {
    // Not shown / permission missing — ignore.
  }
}

/// Push a NEW layout + scale to the RUNNING overlay engine and resize its
/// window to match — called the instant the user picks one in Settings →
/// "Tùy chọn bong bóng nổi".
///
/// Without this, the bubble keeps rendering the OLD layout at the OLD window
/// size until the next navigation sync (the only other place the layout is
/// pushed). The content then gets clipped / overlapped and the speed-limit
/// badge looks missing — the "widget ngang is wrong / cut off / size wrong"
/// bug.
Future<void> pushOverlayLayout(String id, {required double scale}) async {
  overlayLayout = id;
  overlayScale = scale;
  try {
    // Fire-and-forget: the overlay engine may not be listening yet — awaiting
    // would hang (the reply only arrives once it is).
    unawaited(FlutterOverlayWindow.shareData({'layout': id, 'scale': scale}));
  } catch (_) {
    // Overlay not running — nothing to push.
  }
  await resizeOverlayForLayout(id, scale: scale);
}

/// Show the floating widget: draggable, auto-sticks to the right edge.
Future<void> startOverlay() async {
  final granted = await overlayPermissionGranted();
  debugPrint('OVERLAY: startOverlay perm=$granted');
  if (!granted) {
    final ok = await requestOverlayPermission();
    debugPrint('OVERLAY: perm requested -> $ok');
    if (!ok) return;
  }
  // Convert the dp size for current layout to physical px on the default display.
  final (widthDp, heightDp) = overlaySizeDpFor(overlayLayout);
  final views = WidgetsBinding.instance.platformDispatcher.views;
  final dpr = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  debugPrint(
    'OVERLAY: showOverlay layout=$overlayLayout ${widthDp}dpx$heightDp '
    '-> ${(widthDp * dpr).round()}px${(heightDp * dpr).round()}',
  );
  try {
    await FlutterOverlayWindow.showOverlay(
      overlayTitle: 'NavBridge',
      overlayContent: 'Widget tốc độ / giới hạn',
      enableDrag: true,
      width: (widthDp * dpr).round(),
      height: (heightDp * dpr).round(),
      // PositionGravity.none → the bubble is NOT gravity-locked to an edge:
      // it starts where `startPosition` puts it and can be dragged ANYWHERE
      // on the screen (previously `right` snapped it to the edge, so dragging
      // only slid along the right side).
      positionGravity: PositionGravity.none,
      alignment: OverlayAlignment.topRight,
      // Without an explicit start the plugin's default startY is
      // `-statusBarHeightPx()` which pushes the window ABOVE the screen top.
      // y=80dp starts it just below the status bar, fully visible + grabbable.
      startPosition: const OverlayPosition(0, 80),
    );
    debugPrint('OVERLAY: showOverlay returned OK');
    resetOverlayVisibility();
    // Re-push current layout & state after engine bootstrap.
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      syncOverlayState(zoom: 19, radarOn: false, satelliteOn: false);
    });
  } catch (e, s) {
    debugPrint('OVERLAY: showOverlay FAILED: $e\n$s');
  }
}

/// Remove the floating widget.
Future<void> stopOverlay() => FlutterOverlayWindow.closeOverlay();
