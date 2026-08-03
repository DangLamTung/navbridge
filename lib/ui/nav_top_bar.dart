/// Top banner shown while navigating — Google-Maps-style blue turn header:
/// big current-turn arrow + destination, next-turn strip, ETA, exit button.
/// Replaces the search bar during navigation.
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
    this.tripProgress = 0,
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

  /// Fraction of the route completed (0..1) — drives the top progress bar.
  final double tripProgress;

  /// Upcoming maneuvers (shown when [expanded]).
  final List<OsrmStep> steps;

  /// Whether the step list is expanded.
  final bool expanded;

  /// Called when the banner is tapped (toggle the step list).
  final VoidCallback? onToggle;

  String _etaText(NavProgress nav) =>
      '${nav.etaHour.toString().padLeft(2, '0')}:'
      '${nav.etaMinute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final nav = progress;
    return Material(
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(18),
      color: kAppBlue,
      child: InkWell(
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Google-style trip progress bar (thin line at the very top).
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: tripProgress.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
              const SizedBox(height: 8),
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
              // Expandable full step list (Google's tap-the-banner list).
              if (expanded && steps.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
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
                                color: kAppBlue),
                          ),
                          const Spacer(),
                          Icon(Icons.keyboard_arrow_up,
                              size: 16, color: Colors.grey[500]),
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
                              padding:
                                  const EdgeInsets.symmetric(vertical: 3),
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
                                      maneuverIcon(iconForManeuver(
                                          s.type, s.modifier)),
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
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    formatDistance(s.distance),
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.grey[600]),
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
              ],
            ],
          ),
        ),
      ),
    );
  }
}
