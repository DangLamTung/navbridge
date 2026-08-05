/// Top banner shown while navigating — a 1:1 clone of the Vietmap navigation
/// SDK's `BannerInstructionView` (banner_instruction.dart): translucent
/// light-blue rounded bar (height 100, radius 15, margin 10) with a 52px
/// white circular maneuver icon, a 22pt-bold instruction line and the
/// "Còn 500 m, rẽ trái" distance/guide line (22/20pt bold white). Tapping
/// the banner expands a step list below it. Replaces the search bar during
/// navigation.
library;

import 'package:flutter/material.dart';

import '../nav_engine.dart';
import '../nav_protocol.dart';
import '../osrm.dart';
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
    this.steps = const [],
    this.expanded = false,
    this.onToggle,
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

  /// Upcoming maneuvers (shown when [expanded]).
  final List<OsrmStep> steps;

  /// Whether the step list is expanded.
  final bool expanded;

  /// Called when the banner is tapped (toggle the step list).
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final nav = progress;
    // ===== Vietmap BannerInstructionView clone =====
    // Replicates the SDK's banner_instruction.dart 1:1: translucent
    // light-blue rounded bar (height 100, radius 15, margin 10), 52px white
    // circular maneuver icon, 22px-bold instruction, and the
    // "Còn 500 m, rẽ trái" distance/guide line (22/20pt bold white).
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onToggle,
          child: Container(
            margin: const EdgeInsets.all(10),
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.lightBlue.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                const SizedBox(width: 15),
                // White circular maneuver icon (52px) — the SDK banner icon.
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    nav == null ? Icons.navigation : maneuverIcon(nav.iconCode),
                    color: Colors.lightBlue,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Current instruction (next maneuver / road name).
                      Text(
                        nav == null || nav.text.isEmpty
                            ? (destination.isEmpty
                                  ? 'Đang khởi động…'
                                  : destination)
                            : nav.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (nav != null)
                        // "Còn 500 m, rẽ trái" — distance 22pt + guide 20pt.
                        RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            style: const TextStyle(color: Colors.white),
                            children: [
                              const TextSpan(text: 'Còn '),
                              TextSpan(
                                text: formatDistance(nav.meter),
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(
                                text: ', ${maneuverVerb(nav.iconCode)}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // Compact status cluster: trip-recording dot, clock link,
                // stop button (the ETA bar below also has a stop button).
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (recording)
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.white,
                        size: 14,
                      ),
                    Icon(
                      Icons.bluetooth,
                      color: clockConnected
                          ? const Color(0xFFE3F7EC)
                          : Colors.white38,
                      size: 18,
                    ),
                    const SizedBox(height: 2),
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onExit,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.28),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
        // Tap-the-banner extras (only when expanded): next-maneuver strip +
        // full step list, dropped below the banner like the SDK's banner.
        if (expanded) ...[
          if (nav != null && nav.nextIconCode != 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      maneuverIcon(nav.nextIconCode),
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Sau đó: ${nav.nextText.isEmpty ? 'đi tiếp' : nav.nextText}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (stopLabel.isNotEmpty)
                      Text(
                        stopLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (steps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                constraints: const BoxConstraints(maxHeight: 300),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Các bước tiếp theo',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: kAppBlue,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.keyboard_arrow_up,
                          size: 16,
                          color: Colors.grey[500],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: steps.length,
                        itemBuilder: (context, i) {
                          final s = steps[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: kAppBlue,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    maneuverIcon(
                                      iconForManeuver(s.type, s.modifier),
                                    ),
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.name.isEmpty ? 'Đi tiếp' : s.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  formatDistance(s.distance),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
