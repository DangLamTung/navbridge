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
    this.preference = RoutePreference.fastest,
    this.onPreference,
    this.onSaveRoute,
    this.optionsExpanded = true,
    this.onToggleOptions,
    this.onCollapseAll,
    this.elevation,
    this.onSimulate,
    this.onExportGpx,
    this.onExportKml,
    this.onDownloadMap,
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

  /// Route style (nhanh nhất / ngắn nhất / đường chính / đẹp cảnh).
  final RoutePreference preference;
  final ValueChanged<RoutePreference>? onPreference;

  /// One-tap save this route as a favourite (saved plan).
  final VoidCallback? onSaveRoute;

  /// Whether the route-options section (criteria / vehicle / preference) is
  /// expanded. When collapsed the card shows only the selection summary and
  /// stays compact.
  final bool optionsExpanded;
  final VoidCallback? onToggleOptions;

  /// Collapses the WHOLE card back to the compact one-row pill.
  final VoidCallback? onCollapseAll;

  /// Route ascent/descent (best-effort; null = unknown).
  final ElevationInfo? elevation;

  /// Optional: green play button that starts the SIMULATED drive (walks the
  /// route without GPS — for testing maneuvers / camera alerts).
  final VoidCallback? onSimulate;

  /// PLANNING MODE actions (shown as a compact row): export the planned
  /// route to GPX / KML+KMZ, and download the offline map for its area.
  final VoidCallback? onExportGpx;
  final VoidCallback? onExportKml;
  final VoidCallback? onDownloadMap;

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
                if (onCollapseAll != null)
                  IconButton(
                    tooltip: 'Thu gọn lộ trình',
                    icon: Icon(Icons.expand_less, color: Colors.grey[700]),
                    onPressed: onCollapseAll,
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
            // Route options (criteria / vehicle / preference) — collapsible
            // so the card stays compact; the chevron reveals them. When
            // collapsed it shows the current selection summary.
            InkWell(
              onTap: onToggleOptions,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      optionsExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: kAppBlue,
                    ),
                    const SizedBox(width: 6),
                    Icon(profile.icon, size: 16, color: kAppBlue),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        optionsExpanded
                            ? 'Tùy chọn tuyến'
                            : '${profile.label} · ${preference.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF5F6368),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (optionsExpanded) ...[
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
              const SizedBox(height: 8),
              // Route preference: Nhanh nhất · Ngắn nhất · Đường chính · Đẹp cảnh.
              Row(
                children: [
                  for (final p in kRoutePreferences) ...[
                    Expanded(
                      child: _PreferenceChip(
                        preference: p,
                        selected: p == preference,
                        onTap: onPreference == null
                            ? null
                            : () => onPreference!(p),
                      ),
                    ),
                    if (p != kRoutePreferences.last) const SizedBox(width: 6),
                  ],
                ],
              ),
            ],
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
                  if (onSaveRoute != null) ...[const SizedBox(width: 8)],
                  if (onSaveRoute != null)
                    SizedBox(
                      height: 44,
                      width: 52,
                      child: Tooltip(
                        message: 'Lưu tuyến ưa thích',
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF4B400),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: onSaveRoute,
                          child: const Icon(Icons.bookmark_add, size: 24),
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
            // Interactive route editing hint — the route is draggable and a
            // long-press on the map inserts a via point (Google-Maps style).
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.touch_app, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Chạm lâu vào bản đồ để thêm điểm dừng',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ),
                ],
              ),
            ),
            // PLANNING MODE: export the route + download the offline map.
            if (onExportGpx != null ||
                onExportKml != null ||
                onDownloadMap != null) ...[
              const Divider(height: 14),
              Row(
                children: [
                  if (onDownloadMap != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kAppBlue,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: onDownloadMap,
                        icon: const Icon(
                          Icons.download_for_offline_outlined,
                          size: 18,
                        ),
                        label: const Text(
                          'Bản đồ',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  if (onDownloadMap != null && onExportGpx != null)
                    const SizedBox(width: 6),
                  if (onExportGpx != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1E8E3E),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: onExportGpx,
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text(
                          'GPX',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  if (onExportGpx != null && onExportKml != null)
                    const SizedBox(width: 6),
                  if (onExportKml != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFE37400),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: onExportKml,
                        icon: const Icon(Icons.public, size: 16),
                        label: const Text(
                          'KML/KMZ',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One selectable route-preference chip ("Nhanh nhất" · "Ngắn nhất" ·
/// "Đường chính" · "Đẹp cảnh").
class _PreferenceChip extends StatelessWidget {
  const _PreferenceChip({
    required this.preference,
    required this.selected,
    required this.onTap,
  });

  final RoutePreference preference;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : const Color(0xFF5F6368);
    return Tooltip(
      message: preference.hint,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1A73E8) : const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(preference.icon, size: 13, color: fg),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  preference.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
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
