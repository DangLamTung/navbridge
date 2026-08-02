/// Round bluetooth button showing the E-ink clock connection state.
library;

import 'package:flutter/material.dart';

import 'widgets.dart';

class ClockButton extends StatelessWidget {
  const ClockButton({super.key, required this.status, required this.onTap});

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
      icon: Icons.bluetooth,
      color: color,
      onTap: onTap,
      size: 50,
    );
  }
}
