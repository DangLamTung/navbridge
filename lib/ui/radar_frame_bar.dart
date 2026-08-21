/// Compact rain-radar frame selector: "Hiện tại / -20p / … / +10p" chips that
/// switch the radar overlay to that frame — watch the storm move over the
/// past frames, or jump to the nowcast forecast when it's live.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/radar.dart';

class RadarFrameBar extends StatelessWidget {
  const RadarFrameBar({
    super.key,
    required this.frames,
    required this.selected,
    required this.onSelect,
    this.loading = false,
    this.onRefresh,
  });

  /// Frames in chronological order (oldest → newest / forecast).
  final List<RadarFrame> frames;
  final int selected;
  final ValueChanged<int> onSelect;
  final bool loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < frames.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: Text(
                            radarFrameLabel(frames[i]),
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: i == selected,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => onSelect(i),
                          selectedColor: const Color(0xFF1A73E8),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: i == selected
                                ? Colors.white
                                : Colors.black87,
                          ),
                          backgroundColor: Colors.white,
                          side: BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                  ],
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
                tooltip: 'Cập nhật radar',
              ),
          ],
        ),
      ),
    );
  }
}
