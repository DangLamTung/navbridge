/// Round bluetooth button showing the BLE **displays** connection state —
/// the E-ink clock (DA14585) and the ESP32 2.8" nav display (NAV-OSM).
///
/// Tapping opens the device picker, which routes each device to its own BLE
/// client (E-ink clock → [BleClock], ESP display → [BleMapClock]).
library;

import 'package:flutter/material.dart';

import 'package:navbridge/ui/widgets.dart';

class DisplaysButton extends StatelessWidget {
  const DisplaysButton({super.key, required this.status, required this.onTap});

  /// 'off' | 'connecting' | 'connected' — combined across both displays
  /// (any connected = connected).
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
      icon: Icons.bluetooth,
      color: color,
      onTap: onTap,
      size: 44,
    );
  }
}
