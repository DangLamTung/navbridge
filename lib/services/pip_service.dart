/// Picture-in-Picture (PiP) support — Google-Maps "small screen on top".
///
/// Part C of the background-navigation plan. While navigating, the user can
/// shrink the app into a floating PiP window (tapping the nav UI's PiP button,
/// or simply pressing Home — the native side auto-enters PiP on
/// [FlutterActivity.onUserLeaveHint] when nav is active, exactly like Google
/// Maps). The small window keeps showing the live map + maneuver while the
/// phone is used for other apps; the page swaps to a compact layout via
/// [isPipMode] so the huge banner/controls don't overflow the tiny window.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipService {
  PipService._();
  static final PipService instance = PipService._();

  static const MethodChannel _channel = MethodChannel('navbridge/pip');

  /// True while the OS PiP window is on screen. The native side pushes this
  /// on `onPictureInPictureModeChanged`; the nav page listens and renders the
  /// compact PiP layout when it flips on.
  final ValueNotifier<bool> isPipMode = ValueNotifier(false);

  /// Whether the device supports PiP (Android 8+, hardware feature). Cached
  /// after the first check.
  bool? _supported;

  /// Wire up the native → Dart PiP-mode callback. Call once at startup
  /// (the nav page calls this from its [State.initState]).
  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') {
        final active = (call.arguments as Map?)?.containsKey('active') == true
            ? (call.arguments! as Map)['active'] as bool?
            : null;
        isPipMode.value = active ?? false;
      }
    });
  }

  Future<bool> isSupported() async {
    if (_supported != null) return _supported!;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      _supported = false;
    }
    return _supported!;
  }

  Future<bool> isInPip() async {
    try {
      return await _channel.invokeMethod<bool>('isInPip') ?? isPipMode.value;
    } catch (_) {
      return isPipMode.value;
    }
  }

  /// Manually enter PiP (the nav-controls PiP button), with the requested
  /// [aspect] shape ('portrait' | 'landscape'). Returns false if the device
  /// doesn't support it or the system rejected the request.
  Future<bool> enter({String aspect = 'portrait'}) async {
    try {
      return await _channel.invokeMethod<bool>('enter', {'aspect': aspect}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Change the PiP window shape LIVE while it's open (the user picked a
  /// different aspect in settings during navigation). No-op if not in PiP.
  Future<void> setAspect(String aspect) async {
    try {
      await _channel.invokeMethod('setAspect', {'aspect': aspect});
    } catch (_) {}
  }

  /// Tell the native side whether navigation is active, so pressing Home
  /// auto-enters PiP (Google-Maps behavior). Call `true` on nav start and
  /// `false` on nav exit.
  Future<void> setAutoEnter(bool active) async {
    try {
      await _channel.invokeMethod('setAutoEnter', {'active': active});
    } catch (_) {}
  }
}
