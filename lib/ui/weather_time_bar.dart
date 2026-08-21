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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            SizedBox(
              width: 150,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
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
              width: 58,
              child: Text(
                radarFrameLabel(frames[i]),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A73E8),
                ),
              ),
            ),
            if (onRefresh != null)
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 18,
                  color: Color(0xFF1A73E8),
                ),
                visualDensity: VisualDensity.compact,
                onPressed: onRefresh,
                tooltip: 'Cập nhật',
              ),
          ],
        ),
      ),
    );
  }
}
