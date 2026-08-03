/// Bottom card shown when a route is ready but navigation hasn't started.
library;

import 'package:flutter/material.dart';

import '../route_profile.dart';
import 'widgets.dart';

class RoutePreviewCard extends StatelessWidget {
  const RoutePreviewCard({
    super.key,
    required this.etaText,
    required this.distanceText,
    required this.destination,
    required this.onStart,
    required this.onClear,
    required this.profile,
    required this.onProfile,
    this.stopCount = 0,
  });

  /// e.g. "12 ph"
  final String etaText;

  /// e.g. "5,2 km"
  final String distanceText;

  /// Destination display name.
  final String destination;

  final VoidCallback onStart;
  final VoidCallback onClear;

  /// Number of planned stops (multi-stop trip). Shown when > 1.
  final int stopCount;

  /// Active route/road type (car / motorbike / bicycle / walking).
  final RouteProfile profile;
  final ValueChanged<RouteProfile> onProfile;

  @override
  Widget build(BuildContext context) {
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
                Icon(profile.icon, color: kAppBlue, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$etaText • $distanceText'
                        '${stopCount > 1 ? ' • $stopCount điểm dừng' : ''}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        destination,
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
            // Route / road type selector: Ô tô · Xe máy · Xe đạp · Đi bộ.
            Row(
              children: [
                for (final p in kRouteProfiles) ...[
                  Expanded(
                    child: _ProfileChip(
                      profile: p,
                      selected: p == profile,
                      onTap: () => onProfile(p),
                    ),
                  ),
                  if (p != kRouteProfiles.last) const SizedBox(width: 6),
                ],
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAppBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: onStart,
                icon: const Icon(Icons.navigation, size: 20),
                label: const Text(
                  'Bắt đầu chỉ đường',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Xoá lộ trình', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

/// One selectable road-type chip (icon + label).
class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final RouteProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : Colors.grey[700];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kAppBlue : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(profile.icon, size: 18, color: fg),
            const SizedBox(height: 2),
            Text(
              profile.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
