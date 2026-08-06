/// Bottom card shown while navigating — copies the Vietmap SDK's
/// [BottomActionView]: stop button on the left, big amber ETA in the middle
/// (live countdown "X phút" / "X giờ, Y phút"), distance • arrival time
/// below, and an overview button on the right. The time "moves": a 1 s ticker
/// recomputes the remaining time from the fixed arrival moment, so the ETA
/// visibly counts down as the clock advances (even between GPS fixes).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../nav_engine.dart';
import '../nav_protocol.dart';

class NavigationCard extends StatefulWidget {
  const NavigationCard({
    super.key,
    required this.progress,
    required this.onStop,
    this.onOverview,
    this.stopLabel = '',
    this.arrivalTime,
  });

  /// Latest navigation progress (null while starting up).
  final NavProgress? progress;

  final VoidCallback onStop;

  /// Fit-the-route overview action (null hides the overview button).
  final VoidCallback? onOverview;

  /// e.g. "Điểm 2/3" for multi-stop trips (empty for single-destination).
  final String stopLabel;

  /// Fixed arrival moment — the card counts down to it live. Null falls back
  /// to the engine's `etaHour`/`etaMinute`.
  final DateTime? arrivalTime;

  @override
  State<NavigationCard> createState() => _NavigationCardState();
}

class _NavigationCardState extends State<NavigationCard> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Arrival moment: the fixed [widget.arrivalTime], or the engine ETA
  /// (today at etaHour:etaMinute) when none was passed.
  DateTime? get _arrival {
    final at = widget.arrivalTime;
    if (at != null) return at;
    final nav = widget.progress;
    if (nav == null) return null;
    return DateTime(
      _now.year,
      _now.month,
      _now.day,
      nav.etaHour.clamp(0, 23),
      nav.etaMinute.clamp(0, 59),
    );
  }

  /// Remaining duration (live): arrival − now. Clamped to >= 0.
  Duration get _remaining {
    final a = _arrival;
    if (a == null) return Duration.zero;
    return a.difference(_now).isNegative ? Duration.zero : a.difference(_now);
  }

  String _etaText(DateTime a) =>
      '${a.hour.toString().padLeft(2, '0')}:'
      '${a.minute.toString().padLeft(2, '0')}';

  /// Vietmap-style remaining time: "X phút" or "X giờ, Y phút" (live).
  String _durationText(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '$m phút';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '$h giờ' : '$h giờ, $mm phút';
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.progress;
    final a = _arrival;
    final remaining = _remaining;
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Stop navigation button.
            _RoundAction(
              icon: Icons.close,
              onTap: widget.onStop,
              tooltip: 'Kết thúc chỉ đường',
            ),
            const SizedBox(width: 14),
            // Big amber live ETA + distance • arrival.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    nav == null
                        ? 'Đang khởi động…'
                        : a == null
                            ? _durationText(Duration(minutes: 0))
                            : _durationText(remaining),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFF6F00), // amber[900], Vietmap-style
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    nav == null
                        ? '--'
                        : [
                            formatDistance(nav.meter),
                            a == null ? '--' : _etaText(a),
                            if (widget.stopLabel.isNotEmpty) widget.stopLabel,
                          ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, color: Colors.black45),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Overview (fit-route) button.
            if (widget.onOverview != null)
              _RoundAction(
                icon: Icons.route,
                onTap: widget.onOverview!,
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
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black45, width: 1),
          ),
          child: Icon(icon, color: Colors.black45, size: 30),
        ),
      ),
    );
  }
}
