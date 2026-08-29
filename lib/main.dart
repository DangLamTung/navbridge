import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:navbridge/overlay/overlay_main.dart';
import 'package:navbridge/pages/navigation/navigation_page.dart';
import 'package:navbridge/services/nav_foreground.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Port so the background nav task can tell the UI when the notification is
  // tapped (→ reopen the navigation page).
  FlutterForegroundTask.initCommunicationPort();
  // DON'T block the first frame on notification setup (channel creation +
  // POST_NOTIFICATIONS permission dialog). Run it in the background — the
  // nav service is only used once the user starts navigating, by which time
  // init has long finished.
  unawaited(NavForegroundService.instance.init());
  runApp(const NavBridgeApp());
}

/// Secondary entrypoint for the floating speed-limit / camera overlay widget
/// (Waze-Mod style), launched by `flutter_overlay_window` in a separate
/// Flutter engine via `FlutterEngineGroup`.
///
/// IMPORTANT: this MUST be a top-level function in the ROOT library
/// (`lib/main.dart`). The plugin resolves the entrypoint with
/// `DartEntrypoint(bundle, "overlayMain")` — no library URI — so it only
/// looks in the app's main library. Declared anywhere else (e.g. in
/// `overlay_main.dart`), the engine fails with "Could not resolve main
/// entrypoint function" and the overlay shows nothing.
@pragma('vm:entry-point')
Future<void> overlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('OVERLAY: engine started');
  // Capture the overlay's real exceptions (they otherwise print only as
  // "Another exception was thrown: Instance of 'DiagnosticsProperty<void>'"
  // with no stack in release). Temporary diagnostics — remove after fixing.
  final prevFlutterError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails d) {
    debugPrint('OVERLAYERR: ${d.exception}\n${d.stack}');
    prevFlutterError?.call(d);
  };
  WidgetsBinding.instance.platformDispatcher.onError =
      (Object error, StackTrace stack) {
        debugPrint('OVERLAYERR(platform): $error\n$stack');
        return true;
      };
  runApp(const OverlayApp());
}

class NavBridgeApp extends StatelessWidget {
  const NavBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF4285F4);
    return MaterialApp(
      title: 'NavBridge',
      debugShowCheckedModeBanner: false,
      // Lets the notification-tap handler (nav_foreground.dart) pop back to
      // the navigation page from anywhere.
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: blue),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        splashFactory: InkRipple.splashFactory,
      ),
      home: const NavigationPage(),
    );
  }
}
