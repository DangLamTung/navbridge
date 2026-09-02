/// Small reusable pieces for the map screen (shared by multiple widgets).
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/nav_protocol.dart';

/// Google blue used across the app.
const Color kAppBlue = Color(0xFF4285F4);

/// Material icon for a nav-protocol maneuver code (shared by the nav UI).
IconData maneuverIcon(int code) => switch (code) {
  iconTurnLeft => Icons.turn_left,
  iconTurnRight => Icons.turn_right,
  iconSlightLeft => Icons.turn_slight_left,
  iconSlightRight => Icons.turn_slight_right,
  iconUturnLeft => Icons.u_turn_left,
  iconUturnRight => Icons.u_turn_right,
  iconRoundabout => Icons.roundabout_left,
  iconArrive => Icons.flag,
  _ => Icons.straight,
};

/// A round, white, elevated action button (zoom, locate, clock…).
class RoundActionButton extends StatelessWidget {
  const RoundActionButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 46,
    this.child,
    this.onLongPress,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  /// Optional custom icon widget (e.g. the drawn CCTV camera) — overrides
  /// [icon] when provided.
  final Widget? child;

  /// Optional long-press handler (e.g. the mic button long-press toggles the
  /// always-on wake-word listening).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          width: size,
          height: size,
          child: child ?? Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}

/// Green dot marker for the route origin.
class OriginMarker extends StatelessWidget {
  const OriginMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: const Color(0xFF34A853),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
        ),
      ),
    );
  }
}

/// Blue "you are here" dot with a white ring.
class CurrentMarker extends StatelessWidget {
  const CurrentMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: kAppBlue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
        ),
      ),
    );
  }
}

/// Tiny OSM attribution (required by the tile usage policy).
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 2),
      child: Text(
        '© OpenStreetMap',
        style: TextStyle(
          fontSize: 11,
          color: Colors.black54,
          shadows: [Shadow(color: Colors.white, blurRadius: 4)],
        ),
      ),
    );
  }
}

/// Text that auto-scrolls left↔right (marquee) when it doesn't fit the
/// available width, so all of the info is shown instead of being cut off with
/// "…". Used in the tiny PiP window (which can be any shape the user picks)
/// for the current-road name that would otherwise truncate in a narrow window.
/// Render the full text statically when it fits.
class MarqueeText extends StatefulWidget {
  const MarqueeText(this.text, {super.key, this.style, this.velocity = 45});

  final String text;
  final TextStyle? style;

  /// Scroll speed in logical pixels per second.
  final double velocity;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  late final AnimationController _ctrl;
  double _maxScroll = 0;
  bool _overflowed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..addListener(_onTick);
  }

  void _onTick() {
    if (_maxScroll <= 0 || !_scroll.hasClients) return;
    // ping-pong (0 → max → 0) so the text "rolls left right".
    _scroll.jumpTo(_ctrl.value * _maxScroll);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Re-measure the text against the available width. Starts/stops the marquee
  /// based on whether it overflows. Returns true when it overflows.
  bool _measure(double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final textWidth = painter.width;
    painter.dispose();
    final overflow = textWidth > maxWidth + 0.5;
    if (overflow) {
      // Re-measure every build so a PiP resize updates the scroll range/duration
      // (not only on the first overflow) — but don't restart the animation if
      // it's already running.
      _maxScroll = textWidth - maxWidth;
      final dist = _maxScroll;
      _ctrl.duration = Duration(
        milliseconds: (dist / widget.velocity * 1000).round().clamp(
          1500,
          12000,
        ),
      );
      if (!_overflowed || !_ctrl.isAnimating) _ctrl.repeat(reverse: true);
      _overflowed = true;
    } else {
      if (_overflowed) _ctrl.stop();
      _overflowed = false;
      _maxScroll = 0;
    }
    return overflow;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = _measure(
          constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : double.infinity,
        );
        if (!overflow) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: widget.style,
            ),
          );
        }
        return SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(widget.text, maxLines: 1, style: widget.style),
        );
      },
    );
  }
}
