/// Small reusable pieces for the map screen (shared by multiple widgets).
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/nav_protocol.dart';

/// Google blue used across the app.
const Color kAppBlue = Color(0xFF4285F4);

/// Material icon for a nav-protocol maneuver code (shared by the nav UI).
IconData maneuverIcon(int code) => switch (code) {
      iconTurnLeft => Icons.turn_left,
      iconTurnRight => Icons.turn_right,
      iconSlightLeft => Icons.turn_slight_left,
      iconSlightRight => Icons.turn_slight_right,
      iconUturnLeft => Icons.u_turn_left,
      iconUturnRight => Icons.u_turn_right,
      iconRoundabout => Icons.roundabout_left,
      iconArrive => Icons.flag,
      _ => Icons.straight,
    };

/// A round, white, elevated action button (zoom, locate, clock…).
class RoundActionButton extends StatelessWidget {
  const RoundActionButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 46,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}

/// Green dot marker for the route origin.
class OriginMarker extends StatelessWidget {
  const OriginMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: const Color(0xFF34A853),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
        ),
      ),
    );
  }
}

/// Blue "you are here" dot with a white ring.
class CurrentMarker extends StatelessWidget {
  const CurrentMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: kAppBlue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
        ),
      ),
    );
  }
}

/// Tiny OSM attribution (required by the tile usage policy).
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 2),
      child: Text(
        '© OpenStreetMap',
        style: TextStyle(
          fontSize: 11,
          color: Colors.black54,
          shadows: [Shadow(color: Colors.white, blurRadius: 4)],
        ),
      ),
    );
  }
}
