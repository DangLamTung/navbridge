/// Weather-layer time scrubber: a slider that drags through the frames of a
/// weather layer (rain radar or weather satellite) so you can watch the
/// storm / clouds move — past frames and, when live, the nowcast forecast.
///
/// Replaces the old chip row: one slider per layer, showing the selected
/// frame's relative time ("Hiện tại", "-20p", "+10p").
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:navbridge/services/radar.dart';

class WeatherTimeBar extends StatelessWidget {
  const WeatherTimeBar({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.frames,
    required this.selected,
    required this.onSelect,
    this.loading = false,
    this.onRefresh,
  });

  /// Layer name ("Radar" / "Vệ tinh").
  final String title;

  /// Layer icon (water drop for radar, cloud for satellite).
  final IconData icon;

  /// Accent color for the slider + label.
  final Color color;

  /// Frames in chronological order (oldest → newest / forecast).
  final List<RadarFrame> frames;

  /// Index of the selected frame (dragged).
  final int selected;

  final ValueChanged<int> onSelect;

  final bool loading;

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty) return const SizedBox.shrink();
    final i = selected.clamp(0, frames.length - 1);
    final max = math.max(1, frames.length - 1).toDouble();
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      child: Padding(
        // Compact so the floating bar never reaches the right-side map
        // controls on small screens (the old full-width bar overlapped them).
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 4),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            SizedBox(
              width: 104,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  activeTrackColor: color,
                  inactiveTrackColor: color.withValues(alpha: 0.2),
                  thumbColor: color,
                ),
                child: Slider(
                  value: i.toDouble().clamp(0.0, max),
                  max: max,
                  onChanged: frames.length < 2
                      ? null
                      : (v) => onSelect(v.round()),
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                radarFrameLabel(frames[i]),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A73E8),
                ),
              ),
            ),
            if (onRefresh != null)
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 16,
                  color: Color(0xFF1A73E8),
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: onRefresh,
                tooltip: 'Cập nhật',
              ),
          ],
        ),
      ),
    );
  }
}
