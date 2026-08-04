/// Bottom card shown while navigating — copies the Vietmap SDK's
/// [BottomActionView]: stop button on the left, big amber ETA in the middle
/// ("X phút" / "X giờ, Y phút"), distance • arrival time below, and an
/// overview button on the right.
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
    this.onOverview,
    this.stopLabel = '',
  });

  /// Latest navigation progress (null while starting up).
  final NavProgress? progress;

  final VoidCallback onStop;

  /// Fit-the-route overview action (null hides the overview button).
  final VoidCallback? onOverview;

  /// e.g. "Điểm 2/3" for multi-stop trips (empty for single-destination).
  final String stopLabel;

  String _etaText(NavProgress nav) =>
      '${nav.etaHour.toString().padLeft(2, '0')}:'
      '${nav.etaMinute.toString().padLeft(2, '0')}';

  /// Vietmap-style remaining time: "X phút" or "X giờ, Y phút".
  String _durationText(NavProgress nav) {
    final m = nav.etaHour * 60 + nav.etaMinute;
    if (m < 60) return '$m phút';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '$h giờ' : '$h giờ, $mm phút';
  }

  @override
  Widget build(BuildContext context) {
    final nav = progress;
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Stop navigation button.
            _RoundAction(
              icon: Icons.close,
              onTap: onStop,
              tooltip: 'Kết thúc chỉ đường',
            ),
            const SizedBox(width: 14),
            // Big amber ETA + distance • arrival.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    nav == null ? 'Đang khởi động…' : _durationText(nav),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF6F00), // amber[900], Vietmap-style
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    nav == null
                        ? '--'
                        : [
                            formatDistance(nav.meter),
                            _etaText(nav),
                            if (stopLabel.isNotEmpty) stopLabel,
                          ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Overview (fit-route) button.
            if (onOverview != null)
              _RoundAction(
                icon: Icons.route,
                onTap: onOverview!,
                tooltip: 'Xem toàn bộ lộ trình',
              ),
          ],
        ),
      ),
    );
  }
}

/// Circular bordered white action button used by the Vietmap-style bar.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: kAppBlue, width: 1.5),
          ),
          child: Icon(icon, color: kAppBlue, size: 22),
        ),
      ),
    );
  }
}
