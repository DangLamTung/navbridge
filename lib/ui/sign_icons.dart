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

  /// Real sign image for [kind], or null to fall back to the [CustomPaint]
  /// painters below.
  ///
  /// ⭐ ONLY kinds whose bundled artwork has been VISUALLY verified belong in
  /// this list. Four kinds once had an image and drew the WRONG sign while
  /// driving (user: "still using bad sign png in the run"). Audited by laying
  /// every asset out in one labelled sheet (`tools/signs/sign_contact_sheet.py`)
  /// and reading them:
  ///   • `stop.png` — a PHOTO of P.102 "CẤM ĐI NGƯỢC CHIỀU" (no entry),
  ///     watermarked "ThietBiBaoHoLaoDong.Net". The STOP sign is P.101.
  ///   • `give_way.png` — a red-bordered CIRCLE with two opposing arrows;
  ///     P.132 nhường đường is an inverted TRIANGLE.
  ///   • `end_prohibitions.png` — two cars under a strike-through = P.135
  ///     "hết cấm vượt", NOT P.133 "hết mọi lệnh cấm".
  ///   • `no_passing.png` — "cấm vượt đối với XE TẢI" (truck + car); the
  ///     dataset's `no_passing` is the universal sign, so as drawn it tells a
  ///     rider the ban is about trucks.
  /// All four now carry verified artwork again, and since 2026-09-23 so does
  /// every other kind the Waze or VietMap data can emit — the requirement being
  /// that a sign from EITHER source shows the official QCVN picture, not our
  /// drawing (`_StopPainter`, `_YieldPainter`, `_ProhibitionPainter`,
  /// `_CommandPainter`, `_RailwayPainter`, `_InfoPainter` remain only as
  /// fallbacks for kinds no source emits).
  ///
  /// # Provenance of the images that ARE used (all real artwork, not ours)
  ///
  /// | file | source (Wikimedia Commons) | licence |
  /// |------|---------------------------|---------|
  /// | `no_left_turn.png`  | QCVN 41 P.123 cấm rẽ trái | Public domain |
  /// | `no_right_turn.png` | QCVN 41 P.124 cấm rẽ phải | Public domain |
  /// | `no_u_turn.png`     | `Vietnam road sign P124a1.svg` —
  /// Commons description "No U-turn to the left" (VN drives on the right, so
  /// the standard U-turn is made to the left) | Public domain |
  /// | `no_left_uturn.png` | QCVN 41 P.123a cấm rẽ trái VÀ quay đầu —
  /// Commons `Vietnam road sign P124c.svg`, metadata "No left turn or U-turn"
  /// | Public domain |
  /// | `no_right_uturn.png`| QCVN 41 P.124a cấm rẽ phải VÀ quay đầu —
  /// Commons `Vietnam road sign P124d.svg`, metadata "No right turn or U-turn"
  /// | Public domain |
  ///
  /// The two combination kinds used to be PAINTED (a left/right arrow with a
  /// second U-turn arrow stacked over it) — which is not QCVN P.123a/P.124a: the
  /// real sign is ONE arrow that turns and doubles back. User: "cấm rẽ trái và
  /// quay đầu / rẽ phải quay đầu still wrong sign". Both candidates were
  /// verified two ways before bundling: the Commons extmetadata says which side
  /// (`ImageDescription`), and the glyph's ink profile matches the U-turn sign's
  /// (inner-bottom 0.58 and 0.59, against 0.08 for the plain P.123/P.124 arrows),
  /// so they are combinations and not duplicates of the turn signs. A lone
  /// thumbnail description got this BACKWARDS — read the metadata, then measure.
  ///
  /// The U-turn slot used to hold a CẤM VƯỢT image, and was briefly filled with
  /// a sign WE drew (`tools/signs/make_uturn_sign.py`, now historical) — user:
  /// "no u turn find real sign, dont draw anyshit". Fetched with
  /// `Special:FilePath/<title>?width=330`; the description was read from the
  /// file metadata rather than inferred, because a U-turn arrow points down and
  /// reads as a plain "downward arrow" at thumbnail size.
  ///
  /// | `slow_down.png` | W.245a "Slow" (ĐI CHẬM) | Public domain |
  /// | `stop.png` | QCVN 41 P.122 "Stop" — the octagon | Public domain |
  /// | `give_way.png` | QCVN 41 P.132 "Give way to oncoming traffic" (triangle)
  /// | Public domain |
  /// | `no_parking.png` | QCVN 41 P.131a "No parking" | Public domain |
  /// | `no_moto.png` | QCVN 41 P.104 "No motorcycles" | Public domain |
  /// | `no_passing_end.png` | QCVN 41 P.133 "End of the overtaking prohibition"
  /// | Public domain |
  /// | `end_prohibitions.png` | QCVN 41 P.135 "End of all previously signed
  /// prohibitions" — the kind used to be labelled P.133, which is a different
  /// sign | Public domain |
  ///
  /// Four kinds had been dropped to painters because their old PNG held the
  /// WRONG sign (a photo of P.102 in the STOP slot, a circle in the give-way
  /// slot, two cars for end-of-prohibitions, the xe-tải overtaking sign). They
  /// now use real artwork again, verified TWO ways before bundling: the Commons
  /// `ImageDescription` AND the image itself at size in one contact sheet
  /// (`tools/signs/sign_contact_sheet.py`). That method found P.133 to be "end of
  /// the overtaking prohibition" while P.135 is "end of ALL previously signed
  /// prohibitions" — the label this code carried was wrong.
  ///
  /// # 2026-09-23 — every kind the DATA can emit now has official artwork
  ///
  /// Kinds coming out of the Waze decode and the VietMap/DATMAP dumps that still
  /// fell back to a painter were given their real QCVN sign. As before, the
  /// Commons `ImageDescription` was read first and the picture was then looked at
  /// in a labelled sheet; two of these would have been WRONG on the metadata
  /// alone (`R412a` is "Lane for coaches", not a turn sign; `R411` is a
  /// lane-direction board), and the mandatory-direction family needed the eye to
  /// choose: `R301b`/`R301c` draw a flat arrow, `R301d`/`R301e` the turning one.
  ///
  /// | file | Commons source | description as read |
  /// |------|----------------|---------------------|
  /// | `no_passing.png`     | `P.125 (QCVN 41-2019-BGTVT)` | No overtaking (the universal sign — the old bundled file was the xe-tải variant) |
  /// | `no_auto.png`        | `P103a`            | No motor vehicles (the car pictogram) |
  /// | `only_straight.png`  | `R301a`            | Proceed straight ahead only |
  /// | `only_left.png`      | `R301e`            | Các xe chỉ được rẽ trái (turning arrow) |
  /// | `only_right.png`     | `R301d`            | Các xe chỉ được rẽ phải (turning arrow) |
  /// | `one_way.png`        | `I.407a (QCVN 41-2019-BGTVT)` | One way street |
  /// | `railway_crossing.png`| `W242a`           | Railway level crossing (chỗ đường sắt cắt đường bộ) |
  /// | `tunnel.png`         | `W240`             | Tunnel (Đường hầm) |
  ///
  /// `populated` / `populated_end` (R.420 / R.421) are NOT bundled: both kinds are
  /// dropped at load ([droppedSignKinds]) because their data was wrong often
  /// enough to write a wrong speed limit, so no artwork could ever be drawn.
  ///
  /// `test/sign_icons_test.dart` pins this list AND checks every mapped file
  /// exists — add a kind here only after LOOKING at the image.
  static String? assetFor(RoadSignKind kind) => switch (kind) {
    RoadSignKind.stop => '$_assetDir/stop.png',
    RoadSignKind.giveWay => '$_assetDir/give_way.png',
    RoadSignKind.noLeftTurn => '$_assetDir/no_left_turn.png',
    RoadSignKind.noRightTurn => '$_assetDir/no_right_turn.png',
    RoadSignKind.noUTurn => '$_assetDir/no_u_turn.png',
    RoadSignKind.noLeftUTurn => '$_assetDir/no_left_uturn.png',
    RoadSignKind.noRightUTurn => '$_assetDir/no_right_uturn.png',
    RoadSignKind.noParking => '$_assetDir/no_parking.png',
    RoadSignKind.noMoto => '$_assetDir/no_moto.png',
    RoadSignKind.noPassing => '$_assetDir/no_passing.png',
    RoadSignKind.noPassingEnd => '$_assetDir/no_passing_end.png',
    RoadSignKind.endProhibitions => '$_assetDir/end_prohibitions.png',
    RoadSignKind.slowDown => '$_assetDir/slow_down.png',
    RoadSignKind.noAuto => '$_assetDir/no_auto.png',
    RoadSignKind.onlyStraight => '$_assetDir/only_straight.png',
    RoadSignKind.onlyLeft => '$_assetDir/only_left.png',
    RoadSignKind.onlyRight => '$_assetDir/only_right.png',
    RoadSignKind.oneWay => '$_assetDir/one_way.png',
    RoadSignKind.railwayCrossing => '$_assetDir/railway_crossing.png',
    RoadSignKind.tunnel => '$_assetDir/tunnel.png',
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
    final asset = assetFor(kind);
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
        RoadSignKind.speed => CustomPaint(painter: _SpeedPainter(value)),
        RoadSignKind.signal => const CustomPaint(painter: _SignalPainter()),
        RoadSignKind.noPassing => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.cars),
        ),
        RoadSignKind.noAuto => const CustomPaint(
          painter: _ProhibitionPainter(_ProGlyph.auto),
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
        RoadSignKind.tollBooth => const CustomPaint(
          painter: _InfoPainter('TRẠM THU PHÍ'),
        ),
        RoadSignKind.railwayCrossing => const CustomPaint(
          painter: _RailwayPainter(),
        ),
        RoadSignKind.tunnel => const CustomPaint(painter: _InfoPainter('HẦM')),
        // Every kind with real artwork returned above; the two U-turn
        // combinations are among them now (P.123a / P.124a), so their painted
        // stand-ins are gone. Nothing left to draw ⇒ draw nothing rather than
        // invent a sign (user: "dont draw anyshit").
        _ => const SizedBox.shrink(),
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

/// Biển "Hạn chế tốc độ" — white circle, red ring, the limit inside. The only
/// painter a sign-data kind still uses (the km/h comes from the data).
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
  straight,
  bothTurns,
}

class _ProhibitionPainter extends CustomPainter {
  const _ProhibitionPainter(this.glyph);
  final _ProGlyph glyph;

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
    canvas.drawLine(
      Offset(w * 0.20, h * 0.20),
      Offset(w * 0.80, h * 0.80),
      Paint()
        ..color = _signRed
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
      old.glyph != glyph;
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
