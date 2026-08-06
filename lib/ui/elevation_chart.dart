/// Compact route elevation chart (Google-Maps-style) for the nav screen.
/// Draws the elevation profile of the route from the DEM (or SRTM) samples,
/// with the min/max, the ascent/descent totals and the current road grade %
/// at the car's position.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'widgets.dart' show kAppBlue;

class ElevationChart extends StatelessWidget {
  const ElevationChart({
    super.key,
    required this.profile, // (distanceMeters, elevationMeters)
    this.minElev,
    this.maxElev,
    required this.up,
    required this.down,
    this.progress = 0, // 0..1 fraction of the route already driven
    this.compact = false,
  });

  final List<(double, double)> profile;
  final double? minElev;
  final double? maxElev;
  final double up;
  final double down;
  final double progress;
  final bool compact;

  /// Grade (%) of the road at the car: elevation change over the next
  /// ~150 m (or the whole route when near the end). Null when not computable.
  double? _currentGrade() {
    if (profile.length < 2) return null;
    final total = profile.last.$1;
    if (total <= 0) return null;
    final now = progress.clamp(0.0, 1.0) * total;
    final ahead = (now + 150.0).clamp(now, total);

    // Elevation at distance d along the profile (linear between samples).
    double elevAt(double d) {
      if (d <= 0) return profile.first.$2;
      if (d >= total) return profile.last.$2;
      for (var i = 1; i < profile.length; i++) {
        final (dPrev, ePrev) = profile[i - 1];
        final (dCur, eCur) = profile[i];
        if (dCur >= d) {
          final seg = dCur - dPrev;
          final t = seg == 0 ? 0.0 : (d - dPrev) / seg;
          return ePrev + (eCur - ePrev) * t;
        }
      }
      return profile.last.$2;
    }

    final span = ahead - now;
    if (span <= 0) return null;
    return (elevAt(ahead) - elevAt(now)) / span * 100.0;
  }

  @override
  Widget build(BuildContext context) {
    final grade = _currentGrade();
    final lo = minElev ?? profile.map((p) => p.$2).reduce(math.min);
    final hi = maxElev ?? profile.map((p) => p.$2).reduce(math.max);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _Chip(
              icon: Icons.arrow_upward,
              text: '${up.round()}m',
              color: const Color(0xFFC5221F),
            ),
            const SizedBox(width: 8),
            _Chip(
              icon: Icons.arrow_downward,
              text: '${down.round()}m',
              color: const Color(0xFF1E8E3E),
            ),
            const SizedBox(width: 8),
            _Chip(
              icon: Icons.terrain,
              text: '${lo.round()}–${hi.round()}m',
              color: const Color(0xFF5F6368),
            ),
            const Spacer(),
            if (grade != null)
              Text(
                '${grade.abs() < 0.05 ? 0 : grade.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: kAppBlue,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: compact ? 40 : 72,
          child: CustomPaint(
            size: Size.infinite,
            painter: _ElevationPainter(
              profile: profile,
              lo: lo,
              hi: hi,
              progress: progress.clamp(0.0, 1.0),
              grid: !compact,
            ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF202124),
          ),
        ),
      ],
    );
  }
}

class _ElevationPainter extends CustomPainter {
  _ElevationPainter({
    required this.profile,
    required this.lo,
    required this.hi,
    required this.progress,
    required this.grid,
  });

  final List<(double, double)> profile;
  final double lo;
  final double hi;
  final double progress;
  final bool grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (profile.length < 2 || size.width <= 0) return;
    final range = math.max(hi - lo, 1.0);
    final total = profile.last.$1;
    final linePaint = Paint()
      ..color = const Color(0xFF1A73E8)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF1A73E8).withValues(alpha: 0.35),
          const Color(0xFF1A73E8).withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    Offset pt((double, double) p) {
      final x = total <= 0 ? 0.0 : (p.$1 / total) * size.width;
      final y =
          size.height - ((p.$2 - lo) / range) * (size.height - 6) - 3;
      return Offset(x, y.clamp(0.0, size.height));
    }

    if (grid) {
      final gridPaint = Paint()
        ..color = const Color(0xFFE0E0E0)
        ..strokeWidth = 1;
      for (var i = 1; i < 4; i++) {
        final y = size.height * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }

    final path = Path()..moveTo(pt(profile.first).dx, pt(profile.first).dy);
    for (final p in profile.skip(1)) {
      path.lineTo(pt(p).dx, pt(p).dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, fillPaint);
    canvas.drawPath(path, linePaint);

    // Baseline (min elevation) + labels.
    final baseY = pt((0, lo)).dy;
    canvas.drawLine(
      Offset(0, baseY),
      Offset(size.width, baseY),
      Paint()
        ..color = const Color(0xFFB0B0B0)
        ..strokeWidth = 1,
    );

    // Driven-progress marker.
    final px = total <= 0 ? 0.0 : progress * size.width;
    canvas.drawLine(
      Offset(px, 0),
      Offset(px, size.height),
      Paint()
        ..color = const Color(0xFF202124).withValues(alpha: 0.25)
        ..strokeWidth = 1,
    );

    // Current position dot (only when we have a marker).
    if (progress > 0) {
      var my = size.height;
      for (final p in profile) {
        if (p.$1 <= progress * total) {
          my = pt(p).dy;
        } else {
          break;
        }
      }
      canvas.drawCircle(
        Offset(px, my),
        3.5,
        Paint()..color = const Color(0xFF1A73E8),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ElevationPainter old) =>
      old.profile != profile ||
      old.lo != lo ||
      old.hi != hi ||
      old.progress != progress ||
      old.grid != grid;
}
