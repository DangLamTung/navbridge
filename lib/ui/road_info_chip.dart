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
            // Current speed dial — BIG (same scale as the floating speed
            // widget) so it is readable at a glance while riding. Blue ring
            // normally, red fill while speeding.
            _Dial(
              size: 46,
              ringColor: speeding ? const Color(0xFFD93025) : kAppBlue,
              fillColor: speeding ? const Color(0xFFD93025) : Colors.white,
              valueColor: speeding ? Colors.white : kAppBlue,
              big: kmh == null ? '--' : '$kmh',
            ),
            const SizedBox(width: 6),
            // Speed-limit sign. MUST show the EFFECTIVE limit ([limit] =
            // sign-aware override), not [RoadInfo.speedLimit] — showing the
            // road's own tagged value here made the screen disagree with the
            // voice, which announces the effective limit ("voice said 60
            // while the screen showed 50").
            _Dial(
              size: 46,
              ringColor: const Color(0xFFFF5252),
              fillColor: Colors.white,
              valueColor: Colors.black,
              big: (limit == null || limit <= 0) ? '--' : '$limit',
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Primary line: the road class label when meaningful, else
                // the road NAME (a service/footway/pedestrian class has no
                // label — "Đường nội bộ"/"Lối đi bộ" aren't real roads, so
                // we show the actual road name or nothing instead).
                Text(
                  i?.label.isNotEmpty == true
                      ? i!.label
                      : (i?.name.isNotEmpty == true ? i!.name : ''),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: kAppBlue,
                  ),
                ),
                Text(
                  (i != null && i.name.isNotEmpty && i.label.isNotEmpty)
                      ? i.name
                      : '',
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

/// Big circular dial used by the chip: the current speed and the speed-limit
/// sign. Mirrors the floating widget's dials (weight-900 number + tiny "km/h"
/// caption) so both surfaces read the same at a glance.
class _Dial extends StatelessWidget {
  const _Dial({
    required this.size,
    required this.ringColor,
    required this.fillColor,
    required this.valueColor,
    required this.big,
  });

  final double size;
  final Color ringColor;
  final Color fillColor;
  final Color valueColor;
  final String big;

  @override
  Widget build(BuildContext context) {
    // 3-digit limits (100/120) need a slightly smaller number to fit the ring.
    final f = big.length >= 3 ? 0.38 : 0.44;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fillColor,
        border: Border.all(color: ringColor, width: size * 0.12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            big,
            style: TextStyle(
              fontSize: size * f,
              fontWeight: FontWeight.w900,
              height: 1.0,
              letterSpacing: -0.5,
              color: valueColor,
            ),
          ),
          Text(
            'km/h',
            style: TextStyle(
              fontSize: size * 0.16,
              fontWeight: FontWeight.w700,
              height: 1.0,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}
