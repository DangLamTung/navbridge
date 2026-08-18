/// Bottom card shown when a route is ready but navigation hasn't started.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/elevation.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/ui/widgets.dart';

/// 59000 → "59.000 ₫".
String _formatVnd(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '$b ₫';
}

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
    this.tollCost,
    this.alternativeLabels = const [],
    this.selectedAlternative = 0,
    this.onAlternative,
    this.avoidHighway = false,
    this.onToggleAvoidHighway,
    this.avoidFerry = false,
    this.onToggleAvoidFerry,
    this.elevation,
    this.onSimulate,
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

  /// Total toll cost in VND (null = none/unknown).
  final int? tollCost;

  /// Labels for alternative routes (e.g. "12 ph • 7,9 km"). Empty = none.
  final List<String> alternativeLabels;

  /// Currently selected alternative index.
  final int selectedAlternative;

  /// Called when an alternative route chip is tapped.
  final ValueChanged<int>? onAlternative;

  /// Re-route without motorways (route criteria).
  final bool avoidHighway;
  final VoidCallback? onToggleAvoidHighway;

  /// Re-route without ferries (route criteria).
  final bool avoidFerry;
  final VoidCallback? onToggleAvoidFerry;

  /// Route ascent/descent (best-effort; null = unknown).
  final ElevationInfo? elevation;

  /// Optional: green play button that starts the SIMULATED drive (walks the
  /// route without GPS — for testing maneuvers / camera alerts).
  final VoidCallback? onSimulate;

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
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        destination,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Toll cost (Vietmap) — Google warns about tolls on the card.
            if (tollCost != null && tollCost! > 0) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFE08A)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.toll, size: 16, color: Color(0xFFB26A00)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Phí cầu đường: ${_formatVnd(tollCost!)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF7A4F00),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Alternative routes (Vietmap `alternative=true`).
            if (alternativeLabels.length > 1) ...[
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < alternativeLabels.length; i++)
                      Padding(
                        padding: EdgeInsets.only(
                          right: i == alternativeLabels.length - 1 ? 0 : 6,
                        ),
                        child: _AlternativeChip(
                          index: i,
                          label: alternativeLabels[i],
                          selected: i == selectedAlternative,
                          onTap: onAlternative == null
                              ? null
                              : () => onAlternative!(i),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            // Route criteria: elevation + avoid motorways / ferries.
            if (elevation != null ||
                onToggleAvoidHighway != null ||
                onToggleAvoidFerry != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (elevation != null)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0FE),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.terrain,
                              size: 16,
                              color: Color(0xFF1A73E8),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Lên ${elevation!.up.round()} m '
                                '• Xuống ${elevation!.down.round()} m',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF174EA6),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (onToggleAvoidFerry != null)
                    _CriteriaChip(
                      icon: Icons.directions_boat_outlined,
                      label: 'Tránh phà',
                      selected: avoidFerry,
                      onTap: onToggleAvoidFerry!,
                    ),
                  if (onToggleAvoidHighway != null)
                    _CriteriaChip(
                      icon: Icons.directions_car_outlined,
                      label: 'Tránh cao tốc',
                      selected: avoidHighway,
                      onTap: onToggleAvoidHighway!,
                    ),
                ],
              ),
            ],
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
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kAppBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: onStart,
                      icon: const Icon(Icons.navigation, size: 20),
                      label: const Text(
                        'Bắt đầu chỉ đường',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (onSimulate != null) ...[const SizedBox(width: 8)],
                  if (onSimulate != null)
                    SizedBox(
                      height: 44,
                      width: 52,
                      child: Tooltip(
                        message: 'Mô phỏng lái xe (thử nghiệm)',
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF34A853),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: onSimulate,
                          child: const Icon(Icons.play_arrow, size: 26),
                        ),
                      ),
                    ),
                ],
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

/// One route-criteria chip (e.g. "Tránh cao tốc").
class _CriteriaChip extends StatelessWidget {
  const _CriteriaChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : const Color(0xFF5F6368);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kAppBlue : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One selectable alternative-route chip ("Tuyến 2 · 15 ph").
class _AlternativeChip extends StatelessWidget {
  const _AlternativeChip({
    required this.index,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : const Color(0xFF5F6368);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kAppBlue : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tuyến ${index + 1}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
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
            Icon(profile.icon, size: 16, color: fg),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  profile.label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
