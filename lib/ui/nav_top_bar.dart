/// Top bar shown while navigating: destination + ETA + trip/clock status and
/// an exit button. Replaces the search bar during navigation.
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
  });

  /// Destination display name.
  final String destination;

  /// Latest navigation progress (null while starting up).
  final NavProgress? progress;

  final VoidCallback onExit;

  /// True while a trip is being recorded (red dot).
  final bool recording;

  final bool clockConnected;

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
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(28),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              if (recording) ...[
                const Icon(Icons.fiber_manual_record,
                    color: Color(0xFFEA4335), size: 14),
                const SizedBox(width: 6),
              ],
              const Icon(Icons.navigation, color: kAppBlue, size: 20),
              const SizedBox(width: 8),
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
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      nav == null
                          ? 'Đang khởi động…'
                          : 'Đến lúc ${_etaText(nav)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.bluetooth,
                color: clockConnected
                    ? const Color(0xFF34A853)
                    : Colors.blueGrey,
                size: 18,
              ),
              const SizedBox(width: 8),
              InkWell(
                customBorder: const CircleBorder(),
                onTap: onExit,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    color: Color(0xFFEA4335),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
