/// Floating-widget LAYOUT chooser — a dedicated dark settings screen matching
/// the modern Waze/Vietmap HUD customization interface.
///
/// Drivers can choose between "Nằm ngang" and "Nằm dọc" with high-fidelity live
/// previews, adjust the bubble scale slider ("Cỡ bong bóng"), and have their
/// overlay window resize dynamically in real time.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:navbridge/services/overlay_visibility.dart';
import 'package:navbridge/services/overlay_widget.dart';

/// Result object returned when popping [OverlayLayoutScreen].
class OverlayLayoutResult {
  final String layout;
  final double scale;
  const OverlayLayoutResult({required this.layout, required this.scale});
}

class OverlayLayoutScreen extends StatefulWidget {
  final String selected;
  final double scale;

  const OverlayLayoutScreen({
    super.key,
    required this.selected,
    this.scale = 1.0,
  });

  @override
  State<OverlayLayoutScreen> createState() => _OverlayLayoutScreenState();
}

class _OverlayLayoutScreenState extends State<OverlayLayoutScreen> {
  late String _sel;
  late double _scale;

  static const Color _kAccentPink = Color(0xFFFF2D55);
  static const Color _kCardBg = Color(0xFF181A22);
  static const Color _kScreenBg = Color(0xFF0E1015);

  @override
  void initState() {
    super.initState();
    _sel = switch (widget.selected) {
      'horizontal' || 'pill' => 'horizontal',
      _ => 'vertical',
    };
    _scale = widget.scale.clamp(0.8, 2.0);
  }

  void _onSelect(String id) {
    if (_sel == id) return;
    setState(() => _sel = id);
    overlayLayout = id;
    unawaited(resizeOverlayForLayout(id, scale: _scale));
    unawaited(syncOverlayState(zoom: 17, radarOn: false, satelliteOn: false));
  }

  void _onScaleChanged(double val) {
    setState(() => _scale = val);
    overlayScale = val;
    unawaited(resizeOverlayForLayout(_sel, scale: val));
    unawaited(syncOverlayState(zoom: 17, radarOn: false, satelliteOn: false));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kScreenBg,
      appBar: AppBar(
        backgroundColor: _kScreenBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new,
            color: Colors.white,
            size: 20,
          ),
          onPressed: () => Navigator.of(
            context,
          ).pop(OverlayLayoutResult(layout: _sel, scale: _scale)),
        ),
        title: const Text(
          'Tùy chọn bong bóng nổi',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
        children: [
          const Text(
            'Chọn kiểu hiển thị',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),

          // Option 0 (featured): Đồng hồ tốc độ (round gauge)
          _SelectableCard(
            title: 'Đồng hồ tốc độ',
            selected: _sel == 'dial',
            onTap: () => _onSelect('dial'),
            preview: _dialPreview(),
          ),
          const SizedBox(height: 14),

          // Two side-by-side selectable layout cards
          Row(
            children: [
              // Option 1: Nằm ngang (Horizontal)
              Expanded(
                child: _SelectableCard(
                  title: 'Nằm ngang',
                  selected: _sel == 'horizontal',
                  onTap: () => _onSelect('horizontal'),
                  preview: _horizontalPreview(),
                ),
              ),
              const SizedBox(width: 14),
              // Option 2: Nằm dọc (Vertical)
              Expanded(
                child: _SelectableCard(
                  title: 'Nằm dọc',
                  selected: _sel == 'vertical',
                  onTap: () => _onSelect('vertical'),
                  preview: _verticalPreview(),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          // Bubble scale slider section
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1.0,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Cỡ bong bóng',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${(_scale * 100).round()}%',
                      style: const TextStyle(
                        color: _kAccentPink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                    activeTrackColor: _kAccentPink,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                    thumbColor: _kAccentPink,
                    overlayColor: _kAccentPink.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: _scale,
                    min: 0.8,
                    max: 2.0,
                    divisions: 24,
                    onChanged: _onScaleChanged,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Bottom informative card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1.0,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _kAccentPink.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    color: _kAccentPink,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tùy chọn bong bóng nổi',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Chọn bố cục nằm ngang hoặc nằm dọc, đồng thời điều chỉnh kích thước '
                        'bong bóng phù hợp với màn hình và thói quen sử dụng.',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Miniature visual preview of "Đồng hồ tốc độ" (round gauge + limit badge)
  Widget _dialPreview() {
    return Container(
      width: 120,
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF101217),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Mini gauge: charcoal circle with a tick ring.
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF2A2C30), Color(0xFF222428)],
              ),
              border: Border.all(color: const Color(0xFF3A3D43), width: 4),
            ),
            child: CustomPaint(painter: _MiniTicksPainter()),
          ),
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '50',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 7,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          // Limit badge top-right of the dial.
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFF2D55), width: 2.5),
              ),
              child: const Text(
                '50',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Miniature visual preview of "Nằm ngang"
  Widget _horizontalPreview() {
    return Container(
      width: 120,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF101217),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '50',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 6.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          _miniP127Sign('120', size: 26),
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_rounded, color: Colors.amberAccent, size: 12),
              Text(
                '1.0km',
                style: TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 6.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Miniature visual preview of "Nằm dọc"
  Widget _verticalPreview() {
    return Container(
      width: 44,
      height: 120,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF101217),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Icon(Icons.navigation_rounded, color: Colors.white, size: 14),
          _miniP127Sign('80', size: 22),
          const Column(
            children: [
              Text(
                '50',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 6,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Column(
            children: [
              Icon(Icons.videocam_rounded, color: Colors.amberAccent, size: 10),
              Text(
                '1.0km',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 6.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniP127Sign(String speed, {required double size}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD93025), width: size * 0.14),
      ),
      child: Text(
        speed,
        style: TextStyle(
          color: Colors.black,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
    );
  }
}

class _SelectableCard extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget preview;

  const _SelectableCard({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFFFF2D55);
    const cardBg = Color(0xFF181A22);

    return Material(
      color: cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? activeColor : Colors.white.withValues(alpha: 0.08),
          width: selected ? 2.2 : 1.2,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Stack(
          children: [
            Container(
              height: 172,
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Expanded(child: Center(child: preview)),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
            if (selected)
              Positioned(
                bottom: 10,
                right: 10,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: activeColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Draws the small progressive tick ring on the dial preview.
class _MiniTicksPainter extends CustomPainter {
  const _MiniTicksPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    const n = 24;
    const startAngle = 135.0 * (math.pi / 180.0);
    const sweepAngle = 270.0 * (math.pi / 180.0);
    const activeCount = 14;

    for (var i = 0; i < n; i++) {
      final a = startAngle + (i / (n - 1)) * sweepAngle;
      final isActive = i < activeCount;
      final color = isActive
          ? (i > 10 ? const Color(0xFFFF5252) : const Color(0xFFFF9500))
          : const Color(0xFF434B54);
      final tick = Paint()
        ..color = color
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.butt;
      final dx = math.cos(a);
      final dy = math.sin(a);
      canvas.drawLine(
        Offset(c.dx + dx * r * 0.70, c.dy + dy * r * 0.70),
        Offset(c.dx + dx * r * 0.90, c.dy + dy * r * 0.90),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniTicksPainter oldDelegate) => false;
}
