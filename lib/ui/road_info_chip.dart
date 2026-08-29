/// Floating chip shown while navigating: road name, road class and an
/// EU-style speed-limit sign (white circle, red ring).
library;

import 'package:flutter/material.dart';

import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/ui/widgets.dart';

class RoadInfoChip extends StatelessWidget {
  const RoadInfoChip({
    super.key,
    this.info,
    this.loading = false,
    this.speedMps,
    this.limitOverride,
    this.fromEsp = false,
  });

  final RoadInfo? info;
  final bool loading;

  /// True when the fix is coming from the ESP32 GPS bridge (green "ESP" tag),
  /// false = phone GPS (grey "ĐT"). Rendered as a tiny tag inside the chip so
  /// it can never overlap the nav controls column.
  final bool fromEsp;

  /// Current speed in m/s (from GPS) — shown as a Google-style speed pill
  /// that turns red when exceeding the speed limit.
  final double? speedMps;

  /// Sign-aware effective limit (the last speed-limit sign passed, incl.
  /// Waze per-segment data). When set (>0) it wins over [info]'s tagged
  /// limit so the chip mirrors what the driver actually sees on the road.
  final int? limitOverride;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final limit = limitOverride ?? i?.speedLimit;
    final kmh = speedMps == null ? null : (speedMps! * 3.6).round();
    final speeding = limit != null && kmh != null && kmh > limit;
    // GPS-source tag colours (inside the chip — never overlaps the controls).
    final srcColor = fromEsp
        ? const Color(0xFF1A7F37)
        : const Color(0xFF9AA0A6);
    final srcTxt = fromEsp ? 'ESP' : 'ĐT';
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Current speed pill (Google style — red when speeding).
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: speeding ? const Color(0xFFD93025) : Colors.white,
                border: Border.all(
                  color: speeding ? const Color(0xFFD93025) : kAppBlue,
                  width: 3,
                ),
              ),
              child: Text(
                kmh == null ? '--' : '$kmh',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  color: speeding ? Colors.white : kAppBlue,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Speed-limit sign.
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: const Color(0xFFD93025), width: 3),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    i == null ? '--' : '${i.speedLimit}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                    ),
                  ),
                  const Text(
                    'km/h',
                    style: TextStyle(
                      fontSize: 6,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i?.label ?? (loading ? 'Đang tải…' : 'Ngoài đường'),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: kAppBlue,
                  ),
                ),
                Text(
                  (i != null && i.name.isNotEmpty)
                      ? i.name
                      : (i?.highway ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: Colors.grey[700]),
                ),
              ],
            ),
            const SizedBox(width: 4),
            // Tiny "which GPS" dot + tag — green ESP / grey phone.
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: srcColor,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              srcTxt,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: srcColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
