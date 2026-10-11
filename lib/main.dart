import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:navbridge/overlay/overlay_main.dart';
import 'package:navbridge/pages/navigation/navigation_page.dart';
import 'package:navbridge/services/nav_foreground.dart';
import 'package:navbridge/services/offline_router.dart'
    show loadBestGraph, routingGraphPresent;
import 'package:navbridge/services/osrm.dart' show osrmBaseOverride;
import 'package:navbridge/services/trip_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // ⭐ `?osrm=/osrm` points the router at a SAME-ORIGIN relay to the public
    // OSRM server (`tool/sim_serve.py`), because that server sends no CORS
    // headers and a browser fetch to it is blocked — without the relay the web
    // build cannot plan a route at all, and every web feature that needs one
    // (the map route editor, the simulation) silently does nothing.
    final relay = (Uri.base.queryParameters['osrm'] ?? '').trim();
    if (relay.isNotEmpty) {
      osrmBaseOverride = Uri.base.resolve(relay).toString();
      debugPrint('ROUTER: OSRM relay $osrmBaseOverride');
    }
  } else {
    FlutterForegroundTask.initCommunicationPort();
    unawaited(NavForegroundService.instance.init());
    unawaited(recoverSpooledTrips());
    unawaited(_preloadRoutingGraph());
  }
  runApp(const NavBridgeApp());
}

/// Load the offline routing graph as soon as the app boots.
///
/// The navigation page also does this, but only from its `initState` — so a cold
/// start that lands on another screen never loads the graph, and the driver finds
/// "chưa có dữ liệu chỉ đường ngoại tuyến" on the first offline route. Doing it here
/// makes the load independent of which screen happens to open first.
Future<void> _preloadRoutingGraph() async {
  try {
    if (!await routingGraphPresent()) {
      debugPrint('ROUTER: no graph source installed at boot');
      return;
    }
    final ok = await loadBestGraph();
    debugPrint('ROUTER: boot graph preload loaded=$ok');
  } catch (e) {
    debugPrint('ROUTER: boot graph preload failed: $e');
  }
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
