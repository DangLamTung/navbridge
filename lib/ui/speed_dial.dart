/// The floating widget's round speedometer gauge, reusable inside the app.
///
/// The speed widget (a separate Flutter engine over other apps) draws a dark
/// circular face with a 270° sweep of tick marks that fill orange→red as speed
/// rises, the speed in weight-900 type in the middle, and the P.127 limit sign
/// overlapping the top-right. The driver asked for that same look WHILE
/// NAVIGATING ("the speed icon is still not the widget … create a setting for
/// this, have option of widget speed"), so the painter + gauge live here and
/// both surfaces use them — one implementation, no drift.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/ui/widgets.dart';

/// Paints the round speedometer gauge: dark face, progressive orange→red tick
/// sweep (270° from 135°), red when over the posted limit.
class SpeedDialPainter extends CustomPainter {
  final double kmh;
  final int? limit;
  final bool speeding;

  /// Light variant for a white background (the nav chip) instead of the
  /// widget's dark face.
  final bool light;

  const SpeedDialPainter({
    required this.kmh,
    this.limit,
    required this.speeding,
    this.light = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Circular gauge background.
    final bgPaint = Paint()
      ..color = light ? Colors.white : const Color(0xFF2C3238)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(c, r * 0.96, bgPaint);

    // Subtle outer ring.
    final ringPaint = Paint()
      ..color = light ? const Color(0xFFE0E4E8) : const Color(0xFF23282E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(c, r * 0.96, ringPaint);

    // Segmented ticks around the circumference.
    const totalTicks = 34;
    const startAngle = 135.0 * (math.pi / 180.0);
    const sweepAngle = 270.0 * (math.pi / 180.0);

    final maxKmh = math.max(120.0, (limit ?? 90) * 1.3);
    final fraction = (kmh / maxKmh).clamp(0.0, 1.0);
    final activeTickCount = (fraction * totalTicks).round();

    final tickWidth = r * 0.085;
    final tickLength = r * 0.15;
    final tickRadius = r * 0.88;

    for (var i = 0; i < totalTicks; i++) {
      final angle = startAngle + (i / (totalTicks - 1)) * sweepAngle;
      final isActive = i < activeTickCount;

      Color tickColor;
      if (isActive) {
        if (speeding) {
          tickColor = const Color(0xFFFF5252);
        } else {
          tickColor = Color.lerp(
            const Color(0xFFFF9500),
            const Color(0xFFFF3B30),
            i / totalTicks,
          )!;
        }
      } else {
        tickColor = light ? const Color(0xFFD6DAE0) : const Color(0xFF434B54);
      }

      final p = Paint()
        ..color = tickColor
        ..strokeWidth = tickWidth
        ..strokeCap = StrokeCap.butt;

      final inner = Offset(
        c.dx + (tickRadius - tickLength) * math.cos(angle),
        c.dy + (tickRadius - tickLength) * math.sin(angle),
      );
      final outer = Offset(
        c.dx + tickRadius * math.cos(angle),
        c.dy + tickRadius * math.sin(angle),
      );
      canvas.drawLine(inner, outer, p);
    }
  }

  @override
  bool shouldRepaint(covariant SpeedDialPainter old) =>
      old.kmh != kmh ||
      old.limit != limit ||
      old.speeding != speeding ||
      old.light != light;
}

/// The gauge with the live speed centred in it (weight-900 number + "km/h").
class SpeedDial extends StatelessWidget {
  const SpeedDial({
    super.key,
    required this.kmh,
    this.limit,
    this.speeding = false,
    this.size = 104,
    this.light = false,
  });

  final double kmh;
  final int? limit;
  final bool speeding;
  final double size;

  /// White face + dark text (nav chip) instead of the widget's dark face.
  final bool light;

  @override
  Widget build(BuildContext context) {
    final valueColor = speeding
        ? const Color(0xFFFF5252)
        : (light ? kAppBlue : Colors.white);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: SpeedDialPainter(
          kmh: kmh,
          limit: limit,
          speeding: speeding,
          light: light,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Text(
                '${kmh.round()}',
                style: TextStyle(
                  color: valueColor,
                  fontSize: size * 0.33,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'km/h',
                style: TextStyle(
                  color: light ? Colors.grey[600] : Colors.white,
                  fontSize: size * 0.115,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The EU-style posted speed-limit sign: white circle, coral ring, weight-900
/// number. Identical to the one the floating widget overlaps on its dial.
class SpeedLimitBadge extends StatelessWidget {
  const SpeedLimitBadge({super.key, this.limit, this.size = 46});

  final int? limit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l = limit;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFFF5252), width: size * 0.13),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 6,
            offset: Offset(1, 2),
          ),
        ],
      ),
      child: Text(
        l == null || l <= 0 ? '--' : '$l',
        style: TextStyle(
          color: Colors.black,
          fontSize: size * (l != null && l >= 100 ? 0.38 : 0.44),
          fontWeight: FontWeight.w900,
          height: 1.0,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

/// Navigation replacement for [RoadInfoChip] when the "widget" speed style is
/// selected: the widget's dial + overlapping limit sign, with the road name
/// beside it, on the same dark card the nav UI uses for overlays.
class SpeedDialChip extends StatelessWidget {
  const SpeedDialChip({
    super.key,
    this.info,
    this.speedMps,
    this.limitOverride,
    this.limitSrc,
    this.fromEsp = false,
    this.dialSize = 72,
  });

  final RoadInfo? info;
  final double? speedMps;

  /// Sign-aware effective limit (sign/index value) — same input the compact
  /// chip takes, so switching styles never changes the NUMBER shown.
  final int? limitOverride;

  /// Short badge for WHERE the limit came from ('WAZE' / 'SIGN' / 'CITY' …),
  /// shown under the dial. Replaces the street name that used to sit here.
  final String? limitSrc;

  final bool fromEsp;
  final double dialSize;

  @override
  Widget build(BuildContext context) {
    final i = info;
    final limit = limitOverride ?? i?.speedLimit;
    final kmh = speedMps == null || !speedMps!.isFinite ? 0.0 : speedMps! * 3.6;
    final speeding = limit != null && limit > 0 && kmh > limit;
    final srcColor = fromEsp ? const Color(0xFF1A7F37) : Colors.white70;
    final srcTxt = fromEsp ? 'ESP' : 'ĐT';
    final badge = dialSize * 0.58;

    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: const Color(0xE6181A22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dialSize + badge * 0.45,
              height: dialSize + badge * 0.35,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: SpeedDial(
                      kmh: kmh,
                      limit: limit,
                      speeding: speeding,
                      size: dialSize,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: SpeedLimitBadge(limit: limit, size: badge),
                  ),
                ],
              ),
            ),
            // No street name here: the road label/name this widget used to
            // print was frequently the wrong street (the graph and the Waze
            // segment layer disagree at junctions), and next to a speed dial it
            // only invites doubt about the numbers. In its place: WHERE the
            // number came from (WAZE segment / SIGN / CITY rule / CLASS
            // default), which is what actually needs checking on the road.
            const SizedBox(width: 6),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (limitSrc != null && limitSrc!.isNotEmpty)
                  Text(
                    limitSrc!,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.0,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: Color(0xFFB0BEC5),
                    ),
                  ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
