import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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
