/// Real Vietnamese (QCVN 41) road-sign icons for the navigation map.
///
/// Drawn with [CustomPaint] (no SVG/font/emoji dependency) so they render
/// offline on the vector map as Flutter overlays, exactly like the car arrow.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:navbridge/services/offline_road_signs.dart';

/// The Vietnamese traffic-sign red.
const Color _signRed = Color(0xFFC8102E);

/// Renders the sign icon for [kind] (speed signs show [value] km/h).
class SignIcon extends StatelessWidget {
  const SignIcon({super.key, required this.kind, this.value, this.size = 40});

  final RoadSignKind kind;
  final int? value;
  final double size;

  /// Folder with the real QCVN 41 sign PNGs (bundled assets).
  static const String _assetDir = 'assets/offline_map/signs';

  /// Real sign image for [kind], or null to fall back to [CustomPaint]
  /// (dynamic signs such as the speed limit, and signs without a clean
  /// public-domain image).
  static String? _assetFor(RoadSignKind kind) => switch (kind) {
    RoadSignKind.stop => '$_assetDir/stop.png',
    RoadSignKind.giveWay => '$_assetDir/give_way.png',
    RoadSignKind.noPassing => '$_assetDir/no_passing.png',
    RoadSignKind.noLeftTurn => '$_assetDir/no_left_turn.png',
    RoadSignKind.noRightTurn => '$_assetDir/no_right_turn.png',
    RoadSignKind.noUTurn => '$_assetDir/no_u_turn.png',
    RoadSignKind.endProhibitions => '$_assetDir/end_prohibitions.png',
    _ => null,
  };

  /// A short two-line label for signs with no dedicated icon — e.g. the
  /// reserved-lane info sign ("LÀN RIÊNG") so it stays readable at small
  /// map sizes. Null means draw a regular painter instead.
  static String? _infoText(RoadSignKind kind) => switch (kind) {
    RoadSignKind.reservedLane => 'LÀN\nRIÊNG',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final asset = _assetFor(kind);
    if (asset != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Image.asset(asset, fit: BoxFit.contain, gaplessPlayback: true),
      );
    }
    final info = _infoText(kind);
    if (info != null) {
      return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _InfoPainter(info)),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: switch (kind) {
        RoadSignKind.stop => const CustomPaint(painter: _StopPainter()),
        RoadSignKind.giveWay => const CustomPaint(painter: _YieldPainter()),
        RoadSignKind.speed => CustomPaint(painter: _SpeedPainter(value)),
        RoadSignKind.signal => const CustomPaint(painter: _SignalPainter()),
        RoadSignKind.noPassing => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.cars),
        ),
        RoadSignKind.noPassingEnd => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.cars, ended: true),
        ),
        RoadSignKind.noAuto => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.auto),
        ),
        RoadSignKind.noMoto => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.moto),
        ),
        RoadSignKind.noParking => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.parking),
        ),
        RoadSignKind.noLeftTurn => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.leftTurn),
        ),
        RoadSignKind.noRightTurn => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.rightTurn),
        ),
        RoadSignKind.noUTurn => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.uTurn),
        ),
        RoadSignKind.noLeftUTurn => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.leftUTurn),
        ),
        RoadSignKind.noRightUTurn => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.rightUTurn),
        ),
        RoadSignKind.onlyStraight => const CustomPaint(
          painter: _CommandPainter(_CmdDir.straight),
        ),
        RoadSignKind.onlyLeft => const CustomPaint(
          painter: _CommandPainter(_CmdDir.left),
        ),
        RoadSignKind.onlyRight => const CustomPaint(
          painter: _CommandPainter(_CmdDir.right),
        ),
        RoadSignKind.noStraight => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.straight),
        ),
        RoadSignKind.noTurnBoth => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.bothTurns),
        ),
        RoadSignKind.oneWay => const CustomPaint(
          painter: _CommandPainter(_CmdDir.straight),
        ),
        RoadSignKind.reservedLane => const CustomPaint(
          painter: _InfoPainter('LÀN\nRIÊNG'),
        ),
        RoadSignKind.endProhibitions => const CustomPaint(
          painter: _EndProhibitionsPainter(),
        ),
        RoadSignKind.slowDown => const CustomPaint(
          painter: _InfoPainter('GIẢM TỐC ĐỘ'),
        ),
        RoadSignKind.tollBooth => const CustomPaint(
          painter: _InfoPainter('TRẠM THU PHÍ'),
        ),
        RoadSignKind.railwayCrossing => const CustomPaint(
          painter: _RailwayPainter(),
        ),
        RoadSignKind.tunnel => const CustomPaint(painter: _InfoPainter('HẦM')),
      },
    );
  }
}

void _drawText(
  Canvas canvas,
  String text,
  Offset center,
  double size, {
  Color color = Colors.white,
  FontWeight weight = FontWeight.w900,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: weight,
        height: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
}

/// Generic informational sign — a blue rounded square with a short label
/// (toll booth, tunnel, slow-down warnings …). Keeps offline rendering simple.
class _InfoPainter extends CustomPainter {
  const _InfoPainter(this.label);
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.04,
        size.height * 0.04,
        size.width * 0.92,
        size.height * 0.92,
      ),
      Radius.circular(size.width * 0.15),
    );
    canvas.drawRRect(rrect, Paint()..color = const Color(0xFF1A5FB4));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.06
        ..color = Colors.white,
    );
    // Wrap + center so a longer Vietnamese label ("GIẢM TỐC ĐỘ", "TRẠM THU
    // PHÍ") fits the small sign instead of overflowing.
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: size.height * 0.22,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.width * 0.80);
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _InfoPainter old) => old.label != label;
}

/// Đường ngang giao với đường sắt — a white X (crossing) on a red triangle.
class _RailwayPainter extends CustomPainter {
  const _RailwayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Path()
      ..moveTo(w * 0.02, h * 0.02)
      ..lineTo(w * 0.98, h * 0.02)
      ..lineTo(w * 0.5, h * 0.98)
      ..close();
    canvas.drawPath(p, Paint()..color = _signRed);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.07
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.30, h * 0.30),
      Offset(w * 0.70, h * 0.70),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.70, h * 0.30),
      Offset(w * 0.30, h * 0.70),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _RailwayPainter old) => false;
}

/// Biển 122 "STOP" — red octagon with a white border and white text.
class _StopPainter extends CustomPainter {
  const _StopPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 * 0.94;
    final outer = _octagon(c, r);
    canvas.drawPath(outer, Paint()..color = _signRed);
    final inner = _octagon(c, r - size.width * 0.10);
    canvas.drawPath(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.055
        ..color = Colors.white,
    );
    _drawText(canvas, 'STOP', c, size.height * 0.27);
  }

  Path _octagon(Offset c, double r) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final ang = math.pi / 8 + i * math.pi / 4;
      final x = c.dx + r * math.cos(ang);
      final y = c.dy + r * math.sin(ang);
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    return p..close();
  }

  @override
  bool shouldRepaint(covariant _StopPainter old) => false;
}

/// Biển 102 "Nhường đường" — inverted white triangle with a red border.
class _YieldPainter extends CustomPainter {
  const _YieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Path()
      ..moveTo(w * 0.02, h * 0.02)
      ..lineTo(w * 0.98, h * 0.02)
      ..lineTo(w * 0.5, h * 0.98)
      ..close();
    canvas.drawPath(p, Paint()..color = Colors.white);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.09
        ..strokeJoin = StrokeJoin.round
        ..color = _signRed,
    );
    // Inset triangle hint (the point of the sign).
    final inner = Path()
      ..moveTo(w * 0.28, h * 0.30)
      ..lineTo(w * 0.72, h * 0.30)
      ..lineTo(w * 0.5, h * 0.72)
      ..close();
    canvas.drawPath(inner, Paint()..color = _signRed);
  }

  @override
  bool shouldRepaint(covariant _YieldPainter old) => false;
}

/// Biển 127 "Hạn chế tốc độ" — white circle, red ring, the limit inside.
class _SpeedPainter extends CustomPainter {
  const _SpeedPainter(this.value);
  final int? value;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 * 0.96;
    canvas.drawCircle(c, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.10
        ..color = _signRed,
    );
    _drawText(
      canvas,
      value?.toString() ?? '?',
      c,
      size.height * 0.46,
      color: Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) => old.value != value;
}

/// Traffic light (used if the app ever renders lights as icons instead of
/// dots; kept here so the icon set is complete).
class _SignalPainter extends CustomPainter {
  const _SignalPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.28, h * 0.06, w * 0.44, h * 0.88),
      Radius.circular(w * 0.12),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xFF202124));
    const colors = [Color(0xFFEA4335), Color(0xFFF9AB00), Color(0xFF34A853)];
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(w * 0.5, h * (0.22 + i * 0.28)),
        w * 0.13,
        Paint()..color = colors[i],
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SignalPainter old) => false;
}

// --- VN-standard prohibition signs (P.1xx) -------------------------------
// Shared shape: white circle + red ring + red diagonal bar, with a black
// glyph underneath. `ended: true` swaps the bar to grey ("hết lệnh cấm").

enum _ProGlyph {
  cars,
  moto,
  auto,
  parking,
  leftTurn,
  rightTurn,
  uTurn,
  leftUTurn,
  rightUTurn,
  straight,
  bothTurns,
}

class _ProhibitionPainter extends CustomPainter {
  const _ProhibitionPainter(this.glyph, {this.ended = false});
  final _ProGlyph glyph;
  final bool ended;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final c = Offset(w / 2, h / 2);
    final r = math.min(w, h) / 2 * 0.96;
    canvas.drawCircle(c, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.10
        ..color = _signRed,
    );
    final barColor = ended ? Colors.black38 : _signRed;
    canvas.drawLine(
      Offset(w * 0.20, h * 0.20),
      Offset(w * 0.80, h * 0.80),
      Paint()
        ..color = barColor
        ..strokeWidth = w * 0.085
        ..strokeCap = StrokeCap.round,
    );
    final ink = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.fill
      ..strokeWidth = w * 0.06
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case _ProGlyph.cars:
        _drawCar(canvas, Offset(w * 0.32, h * 0.40), w * 0.20, h * 0.10, ink);
        _drawCar(canvas, Offset(w * 0.64, h * 0.40), w * 0.20, h * 0.10, ink);
      case _ProGlyph.auto:
        // Single car (P.124a "Cấm ô tô").
        _drawCar(canvas, Offset(w * 0.40, h * 0.40), w * 0.22, h * 0.11, ink);
      case _ProGlyph.moto:
        _drawMoto(canvas, Offset(w * 0.42, h * 0.42), w * 0.20, ink);
      case _ProGlyph.parking:
        _drawParking(canvas, size, ink);
      case _ProGlyph.leftTurn:
        _drawTurnArrow(canvas, size, left: true, ink: ink);
      case _ProGlyph.rightTurn:
        _drawTurnArrow(canvas, size, left: false, ink: ink);
      case _ProGlyph.uTurn:
        _drawUTurn(canvas, size, left: true, ink: ink);
      case _ProGlyph.leftUTurn:
        _drawTurnArrow(canvas, size, left: true, ink: ink);
        _drawUTurn(canvas, size, left: true, ink: ink, up: h * 0.30);
      case _ProGlyph.rightUTurn:
        _drawTurnArrow(canvas, size, left: false, ink: ink);
        _drawUTurn(canvas, size, left: false, ink: ink, up: h * 0.30);
      case _ProGlyph.straight:
        // P.112 Cấm đi thẳng — an up arrow.
        _drawStraightArrow(canvas, size, ink);
      case _ProGlyph.bothTurns:
        _drawTurnArrow(canvas, size, left: true, ink: ink);
        _drawTurnArrow(canvas, size, left: false, ink: ink);
    }
  }

  void _drawMoto(Canvas canvas, Offset c, double w, Paint ink) {
    // Motorcycle silhouette: two wheels + body.
    canvas.drawCircle(
      Offset(c.dx, c.dy + w * 0.30),
      w * 0.14,
      ink..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(c.dx + w * 1.0, c.dy + w * 0.30),
      w * 0.14,
      ink..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(c.dx, c.dy + w * 0.30),
      w * 0.14,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.10,
    );
    canvas.drawCircle(
      Offset(c.dx + w * 1.0, c.dy + w * 0.30),
      w * 0.14,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.10,
    );
    canvas.drawLine(
      Offset(c.dx + w * 0.16, c.dy + w * 0.26),
      Offset(c.dx + w * 0.84, c.dy + w * 0.26),
      ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.16,
    );
  }

  void _drawParking(Canvas canvas, Size size, Paint ink) {
    // "P" glyph for P.131a cấm đỗ xe.
    _drawText(
      canvas,
      'P',
      Offset(size.width / 2, size.height / 2),
      size.height * 0.42,
      color: Colors.black87,
    );
  }

  void _drawStraightArrow(Canvas canvas, Size size, Paint ink) {
    final w = size.width, h = size.height;
    canvas.drawLine(
      Offset(w * 0.5, h * 0.32),
      Offset(w * 0.5, h * 0.68),
      ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.10,
    );
    final head = Path()
      ..moveTo(w * 0.5, h * 0.22)
      ..lineTo(w * 0.32, h * 0.44)
      ..lineTo(w * 0.68, h * 0.44)
      ..close();
    canvas.drawPath(head, ink..style = PaintingStyle.fill);
  }

  void _drawCar(Canvas canvas, Offset topLeft, double w, double h, Paint ink) {
    // simple car: body + cabin + wheels
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(topLeft.dx, topLeft.dy, w, h),
        Radius.circular(h * 0.3),
      ),
      ink,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        topLeft.dx + w * 0.18,
        topLeft.dy - h * 0.4,
        w * 0.45,
        h * 0.55,
      ),
      ink,
    );
    canvas.drawCircle(
      Offset(topLeft.dx + w * 0.25, topLeft.dy + h),
      w * 0.09,
      ink,
    );
    canvas.drawCircle(
      Offset(topLeft.dx + w * 0.75, topLeft.dy + h),
      w * 0.09,
      ink,
    );
  }

  void _drawTurnArrow(
    Canvas canvas,
    Size size, {
    required bool left,
    required Paint ink,
  }) {
    final w = size.width, h = size.height;
    final cy = h * 0.60;
    // P.123 (cấm rẽ trái) / P.124 (cấm rẽ phải): the arrow TURNS toward the
    // named side and its head sits there. (This was mirrored before — for
    // `left` the stem went RIGHT while the arrowhead pointed left, so the
    // cấm rẽ trái sign looked like a right turn.)
    final stemStart = Offset(left ? w * 0.62 : w * 0.38, cy);
    final stemEnd = Offset(left ? w * 0.38 : w * 0.62, cy);
    final tip = Offset(left ? w * 0.28 : w * 0.72, h * 0.30);
    final path = Path()..moveTo(stemStart.dx, stemStart.dy);
    path.lineTo(stemEnd.dx, stemEnd.dy);
    path.lineTo(tip.dx, tip.dy);
    canvas.drawPath(path, ink..style = PaintingStyle.stroke);
    // Arrowhead. The head must sit BEHIND the tip, i.e. on the side the stem
    // came from (down-right of the tip when turning left, down-left when
    // turning right), otherwise the apex faces back along the stem and the
    // glyph reads as a turn the wrong way. The old code put the base on the
    // opposite side for both cases:
    //   left  -> base at tip.dx - 0.10w  (base LEFT of the apex => head
    //            pointed RIGHT while the stem bent left)
    //   right -> base at tip.dx + 0.10w  (mirror of the same mistake)
    final back = left ? w * 0.10 : -w * 0.10;
    final a1 = Offset(tip.dx + back, tip.dy + h * 0.06);
    final a2 = Offset(tip.dx + back, tip.dy - h * 0.06);
    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(a1.dx, a1.dy)
      ..lineTo(a2.dx, a2.dy)
      ..close();
    canvas.drawPath(head, ink..style = PaintingStyle.fill);
  }

  void _drawUTurn(
    Canvas canvas,
    Size size, {
    required bool left,
    required Paint ink,
    double? up,
  }) {
    final w = size.width, h = size.height;
    final y = up ?? h * 0.52;
    final r = w * 0.12;
    final endX = left ? w * 0.24 : w * 0.76;
    final path = Path();
    if (left) {
      path.moveTo(w * 0.28, y);
      path.arcToPoint(
        Offset(w * 0.56, y),
        radius: Radius.circular(r),
        clockwise: true,
      );
      path.moveTo(w * 0.56, y);
      path.lineTo(endX, y);
    } else {
      path.moveTo(w * 0.72, y);
      path.arcToPoint(
        Offset(w * 0.44, y),
        radius: Radius.circular(r),
        clockwise: false,
      );
      path.moveTo(w * 0.44, y);
      path.lineTo(endX, y);
    }
    canvas.drawPath(path, ink..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _ProhibitionPainter old) =>
      old.glyph != glyph || old.ended != ended;
}

/// Biển P.133 "Hết mọi lệnh cấm" — white circle, thin black ring, thick
/// grey diagonal bar (no red).
class _EndProhibitionsPainter extends CustomPainter {
  const _EndProhibitionsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final c = Offset(w / 2, h / 2);
    final r = math.min(w, h) / 2 * 0.96;
    canvas.drawCircle(c, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.045
        ..color = Colors.black54,
    );
    canvas.drawLine(
      Offset(w * 0.22, h * 0.22),
      Offset(w * 0.78, h * 0.78),
      Paint()
        ..color = Colors.black45
        ..strokeWidth = w * 0.12
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _EndProhibitionsPainter old) => false;
}

/// Biển R.41x "Hướng phải đi / rẽ" — blue circle, white arrow.
enum _CmdDir { straight, left, right }

class _CommandPainter extends CustomPainter {
  const _CommandPainter(this.dir);
  final _CmdDir dir;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final c = Offset(w / 2, h / 2);
    final r = math.min(w, h) / 2 * 0.96;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF1565C0));
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.10
      ..strokeCap = StrokeCap.round;
    switch (dir) {
      case _CmdDir.straight:
        canvas.drawLine(
          Offset(w * 0.5, h * 0.30),
          Offset(w * 0.5, h * 0.70),
          white,
        );
        final head = Path()
          ..moveTo(w * 0.5, h * 0.24)
          ..lineTo(w * 0.36, h * 0.42)
          ..lineTo(w * 0.64, h * 0.42)
          ..close();
        canvas.drawPath(head, Paint()..color = Colors.white);
      case _CmdDir.left:
        final p = Path()
          ..moveTo(w * 0.68, h * 0.30)
          ..lineTo(w * 0.68, h * 0.62)
          ..lineTo(w * 0.38, h * 0.62);
        canvas.drawPath(p, white);
        final head = Path()
          ..moveTo(w * 0.30, h * 0.62)
          ..lineTo(w * 0.48, h * 0.46)
          ..lineTo(w * 0.48, h * 0.78)
          ..close();
        canvas.drawPath(head, Paint()..color = Colors.white);
      case _CmdDir.right:
        final p = Path()
          ..moveTo(w * 0.32, h * 0.30)
          ..lineTo(w * 0.32, h * 0.62)
          ..lineTo(w * 0.62, h * 0.62);
        canvas.drawPath(p, white);
        final head = Path()
          ..moveTo(w * 0.70, h * 0.62)
          ..lineTo(w * 0.52, h * 0.46)
          ..lineTo(w * 0.52, h * 0.78)
          ..close();
        canvas.drawPath(head, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _CommandPainter old) => old.dir != dir;
}
