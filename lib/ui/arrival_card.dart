/// Google-style arrival card shown when the destination is reached:
/// big green check, "Bạn đã đến nơi", the stop name and a red end button.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/nav_engine.dart';

class ArrivalCard extends StatelessWidget {
  const ArrivalCard({
    super.key,
    required this.progress,
    required this.onStop,
    this.stopLabel = '',
  });

  /// Latest navigation progress (must be in the "arrive" state).
  final NavProgress progress;

  final VoidCallback onStop;

  /// e.g. "Điểm 2/3" for multi-stop trips (empty for single-destination).
  final String stopLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFF34A853),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.flag, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Bạn đã đến nơi',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        progress.stopName.isEmpty
                            ? (stopLabel.isEmpty ? 'Điểm đến' : stopLabel)
                            : progress.stopName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 42,
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
