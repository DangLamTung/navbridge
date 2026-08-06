/// Right-hand vertical map controls: zoom in / zoom out / my location.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/ui/widgets.dart';

class MapControls extends StatelessWidget {
  const MapControls({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onLocate,
    this.hasPosition = false,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onLocate;

  /// Whether a GPS position is available (enables the locate button).
  final bool hasPosition;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundActionButton(icon: Icons.add, color: kAppBlue, onTap: onZoomIn),
        const SizedBox(height: 8),
        RoundActionButton(icon: Icons.remove, color: kAppBlue, onTap: onZoomOut),
        const SizedBox(height: 8),
        RoundActionButton(
          icon: Icons.my_location,
          color: hasPosition ? kAppBlue : Colors.grey,
          onTap: onLocate,
        ),
      ],
    );
  }
}
