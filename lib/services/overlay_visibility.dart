/// Bridges the floating widget's visibility from the MAIN app to the overlay
/// engine (a separate Flutter engine launched by `flutter_overlay_window`).
///
/// The overlay is only useful at street level while driving, and it runs a
/// second Flutter engine + its own GPS stream — so on a low-end phone it
/// steals CPU/GPU from the map (lag, especially over the heavy rain-radar /
/// weather-satellite layers). The main app pushes a `hidden` flag whenever
/// the map state changes; the overlay engine stops its GPS + lookups while
/// hidden ("make it not run") and resumes when it should show again.
library;

import 'dart:async';

import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// The next-maneuver snippet the floating widget shows (Vietmap-Live style
/// "← 750 m"), sourced from the main app's nav engine — the overlay engine
/// can't compute it itself (it has no route).
class OverlayManeuver {
  final int iconCode;
  final int meters;
  final String text; // road you turn into ('' when none)
  const OverlayManeuver(this.iconCode, this.meters, this.text);
}

/// One nearby road-sign chip the floating widget shows (icon + distance).
/// Several are pushed at once — every sign within 300 m, plus zone-boundary
/// signs farther out — so the driver sees them all as they approach.
class OverlaySign {
  final String kind; // RoadSignKind.key
  final int? value; // km/h for speed signs
  final String? text; // Vietnamese name
  final int meters;
  const OverlaySign(this.kind, this.value, this.text, this.meters);
}

/// Active floating-widget layout id ('vertical' | 'horizontal').
/// Picked in Settings → "Tùy chọn bong bóng nổi" and sent to the overlay engine
/// via [syncOverlayState] so the second engine renders the chosen layout.
String overlayLayout = 'vertical';

/// Active scale multiplier (0.8 to 1.5, default 1.0).
double overlayScale = 1.0;

bool _hidden = false;
int? _lastManeuverIcon;
int? _lastManeuverMeters;
int? _lastLimit;
int? _lastCameras;
String? _lastLayout;
double? _lastScale;
String? _lastSigns;

/// Push the overlay's state (hidden flag + next maneuver + speed limit +
/// camera distance) to the second engine. The limit/camera come from the MAIN
/// app (its own nav engine + offline layers), so the overlay does NOT load
/// the 22 MB speed layer / camera index itself — that extra load on a low-end
/// phone is what made the app freeze while navigating.
///
/// Cheap: repeated calls with identical state are no-ops (deduped here), so it
/// can be called from the 1 Hz GPS tick + the radar/satellite toggles.
///
/// Fire-and-forget (never awaited): if the overlay engine isn't listening yet
/// (or the overlay is off) the reply never arrives and awaiting would hang.
Future<void> syncOverlayState({
  required double zoom,
  required bool radarOn,
  required bool satelliteOn,
  OverlayManeuver? maneuver,
  int? limit,

  /// Camera distances (metres) to show — every camera within 600 m. Null
  /// keeps whatever the overlay currently shows.
  List<int>? cameras,
  double? speedKmh,

  /// Nearby sign chips to show (every sign within 600 m + zone-boundary signs
  /// beyond). Null keeps whatever the overlay currently shows.
  List<OverlaySign>? signs,

  /// Auto-hide only applies while the user is ACTIVELY navigating in
  /// NavBridge. Over any other app (the widget's main use — Google Maps /
  /// Waze) or while just browsing, the bubble must NEVER hide: hiding was
  /// tied to the NavBridge map zoom/radar state, so over Google Maps the
  /// backgrounded app's low zoom (startup is z13 < kOverlayHideZoom 15) kept
  /// pushing hidden=true and the widget vanished.
  bool navigating = false,
}) async {
  // ⭐ The widget is ALWAYS visible when enabled in Settings — never
  // auto-hide. The old rule hid it while navigating whenever the map zoom was
  // below z15 (or radar/satellite on), so the traffic sign vanished exactly
  // when driving (log: `hidden=true` pushed every second). The user: "not
  // show the trafic sign now". The bubble is small + draggable and shows the
  // posted limit / cameras / signs — keep it up whenever enabled.
  final hide = false;
  final icon = maneuver?.iconCode;
  final meters = maneuver?.meters;
  final signSig = signs == null
      ? null
      : '${signs.length}:${signs.fold<int>(0, (a, s) => a + s.kind.hashCode * 31 + s.meters)}';
  final camSig = cameras?.fold<int>(0, (a, c) => a * 31 + c);
  if (hide == _hidden &&
      icon == _lastManeuverIcon &&
      meters == _lastManeuverMeters &&
      limit == _lastLimit &&
      camSig == _lastCameras &&
      overlayLayout == _lastLayout &&
      overlayScale == _lastScale &&
      speedKmh == null &&
      signSig == _lastSigns) {
    return;
  }
  _hidden = hide;
  _lastManeuverIcon = icon;
  _lastManeuverMeters = meters;
  _lastLimit = limit;
  _lastCameras = camSig;
  _lastLayout = overlayLayout;
  _lastScale = overlayScale;
  _lastSigns = signSig;
  try {
    unawaited(
      FlutterOverlayWindow.shareData({
        'hidden': hide,
        'mIcon': icon,
        'mMeters': meters,
        'mText': maneuver?.text ?? '',
        'limit': limit,
        'cameras': cameras,
        'layout': overlayLayout,
        'scale': overlayScale,
        'kmh': ?speedKmh,
        'signs': signs == null
            ? null
            : [
                for (final s in signs)
                  {'k': s.kind, 'v': s.value, 't': s.text, 'm': s.meters},
              ],
      }),
    );
  } catch (_) {
    // Overlay not running — nothing to sync.
  }
}

/// Reset the dedupe latches (used on app lifecycle resume so a stale "shown"
/// state can't suppress a fresh hide).
void resetOverlayVisibility() {
  _hidden = false;
  _lastManeuverIcon = null;
  _lastManeuverMeters = null;
  _lastLimit = null;
  _lastCameras = null;
  _lastLayout = null;
  _lastScale = null;
  _lastSigns = null;
}
