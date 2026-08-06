import 'package:flutter/material.dart';

import 'package:navbridge/pages/navigation/navigation_page.dart';

void main() {
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
