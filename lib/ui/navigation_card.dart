/// Bottom card shown while navigating: maneuver icon, distance, ETA, speed.
library;

import 'package:flutter/material.dart';

import '../nav_engine.dart';
import '../nav_protocol.dart';
import 'widgets.dart';

class NavigationCard extends StatelessWidget {
  const NavigationCard({
    super.key,
    required this.progress,
    required this.onStop,
  });

  /// Latest navigation progress (null while starting up).
  final NavProgress? progress;

  final VoidCallback onStop;

  IconData _iconFor(int code) => switch (code) {
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

  String _etaText(NavProgress nav) =>
      '${nav.etaHour.toString().padLeft(2, '0')}:'
      '${nav.etaMinute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final nav = progress;
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration:
                      const BoxDecoration(color: kAppBlue, shape: BoxShape.circle),
                  child: Icon(
                    nav == null ? Icons.navigation : _iconFor(nav.iconCode),
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nav == null ? 'Đang khởi động…' : formatDistance(nav.meter),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        nav?.text ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatChip(
                  icon: Icons.schedule,
                  label: nav == null ? '--' : _etaText(nav),
                ),
                StatChip(
                  icon: Icons.speed,
                  label: nav == null
                      ? '--'
                      : '${(nav.speedMps * 3.6).round()} km/h',
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEA4335),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle, size: 18),
                label: const Text(
                  'Kết thúc chỉ đường',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
