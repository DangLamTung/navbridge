/// Top banner shown while navigating — Google-Maps-style blue turn header:
/// big current-turn arrow + destination, next-turn strip, ETA, exit button.
/// Replaces the search bar during navigation.
library;

import 'package:flutter/material.dart';

import '../nav_engine.dart';
import 'widgets.dart';

class NavTopBar extends StatelessWidget {
  const NavTopBar({
    super.key,
    required this.destination,
    required this.progress,
    required this.onExit,
    this.recording = false,
    this.clockConnected = false,
    this.stopLabel = '',
  });

  /// Destination display name.
  final String destination;

  /// Latest navigation progress (null while starting up).
  final NavProgress? progress;

  final VoidCallback onExit;

  /// True while a trip is being recorded (red dot).
  final bool recording;

  final bool clockConnected;

  /// e.g. "Điểm 2/3" for multi-stop trips.
  final String stopLabel;

  String _etaText(NavProgress nav) =>
      '${nav.etaHour.toString().padLeft(2, '0')}:'
      '${nav.etaMinute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final nav = progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        elevation: 6,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(18),
        color: kAppBlue,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (recording) ...[
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.white, size: 14),
                    const SizedBox(width: 6),
                  ],
                  // Big current-turn arrow.
                  Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: Icon(
                      nav == null ? Icons.navigation : maneuverIcon(nav.iconCode),
                      color: kAppBlue,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          destination,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                        Text(
                          nav == null
                              ? 'Đang khởi động…'
                              : 'Về ${nav.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (nav != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _etaText(nav),
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Colors.white),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.bluetooth,
                    color: clockConnected
                        ? const Color(0xFFB7E5C7)
                        : Colors.white38,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onExit,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
              // Next-turn strip (Google-style "after this, …").
              if (nav != null && nav.nextIconCode != 0) ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(maneuverIcon(nav.nextIconCode),
                          color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Sau đó: ${nav.nextText.isEmpty ? 'đi tiếp' : nav.nextText}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                      ),
                      if (stopLabel.isNotEmpty)
                        Text(stopLabel,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
