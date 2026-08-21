/// Round bluetooth button showing the ESP32 2.8" navigation display
/// (NAV-OSM board) connection state.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/ui/widgets.dart';

class MapButton extends StatelessWidget {
  const MapButton({super.key, required this.status, required this.onTap});

  /// 'off' | 'connecting' | 'connected'
  final String status;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'connected' => const Color(0xFF34A853),
      'connecting' => Colors.orange,
      _ => Colors.blueGrey,
    };
    return RoundActionButton(
      icon: Icons.map_outlined,
      color: color,
      onTap: onTap,
      size: 44,
    );
  }
}
