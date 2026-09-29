/// The "Tiếp tục" offer shown on the map after navigation is turned off.
///
/// The trip the driver was on is remembered (destination, stop order, routing
/// choices) even though its route is not — a route must be rebuilt from where
/// the car is now, so this bar only names where the driver was going and asks
/// to go there again.
library;

import 'package:flutter/material.dart';

import 'widgets.dart';

class ResumeTripBar extends StatelessWidget {
  const ResumeTripBar({
    super.key,
    required this.label,
    required this.onContinue,
    required this.onDismiss,
    this.busy = false,
  });

  /// Where the driver was heading (already fallback-safe).
  final String label;
  final VoidCallback onContinue;

  /// Forget the offer — the ✕.
  final VoidCallback onDismiss;

  /// True while a route is being built for the offer: the button waits rather
  /// than starting a second build.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(
          children: [
            const Icon(Icons.play_circle_outline, color: kAppBlue, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Chuyến đi đang dở',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: busy ? null : onContinue,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Tiếp tục', style: TextStyle(fontSize: 13)),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Bỏ lời mời',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
