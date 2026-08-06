/// Google-Maps-style bottom status bar shown while navigating: the live
/// clock, remaining distance, ETA (time remaining), the current weather and
/// a draggable trip progress line. The route elevation (terrain) chart is a
/// SECOND slide — the driver chooses which ONE to see (path-time or
/// elevation), never both at once.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../nav_protocol.dart';
import '../weather.dart';
import 'widgets.dart' show kAppBlue;

/// Which bottom-bar "slide" is visible: the path-time progress or the
/// elevation (terrain) chart.
enum NavBarMode { time, elevation }

class NavStatusBar extends StatefulWidget {
  const NavStatusBar({
    super.key,
    required this.remainingMeters,
    required this.etaMinutes,
    required this.progress, // 0..1 fraction of the route already driven
    this.weather,
    this.elevation,
    this.onScrub,
    this.onScrubEnd,
    this.previewProgress,
    this.mode = NavBarMode.time,
    this.onModeChanged,
    this.destination,
    this.dark = false,
  });

  final double remainingMeters;
  final int etaMinutes;
  final double progress;

  /// Current weather (temp / feels-like / humidity / wind) — richer than the
  /// single °C. Null hides the weather row.
  final WeatherInfo? weather;

  /// Optional terrain/elevation widget rendered inside the same card (so the
  /// bottom bar and the terrain strip live at the same place).
  final Widget? elevation;

  /// Called while the user drags the progress line (0..1 scrubbed fraction).
  final ValueChanged<double>? onScrub;

  /// Called when the user releases the progress line.
  final VoidCallback? onScrubEnd;

  /// Scrub preview progress (overrides [progress] while dragging).
  final double? previewProgress;

  /// Selected slide: the path-time progress or the elevation chart.
  final NavBarMode mode;

  /// Called when the driver switches the slide (time <-> elevation).
  final ValueChanged<NavBarMode>? onModeChanged;

  /// Destination display name — shown next to the progress bar's flag.
  final String? destination;

  final bool dark;

  @override
  State<NavStatusBar> createState() => _NavStatusBarState();
}

class _NavStatusBarState extends State<NavStatusBar> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Update the clock every second — the time "moves" live.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String get _clock {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  double get _effectiveProgress =>
      (widget.previewProgress ?? widget.progress).clamp(0.0, 1.0);

  void _scrubAt(double dx, double width) {
    if (width <= 0 || widget.onScrub == null) return;
    final p = (dx / width).clamp(0.0, 1.0);
    widget.onScrub!(p);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.dark ? Colors.white : const Color(0xFF202124);
    final sub = widget.dark ? Colors.white70 : const Color(0xFF5F6368);
    final minutes = widget.etaMinutes > 0 ? widget.etaMinutes : 0;
    final w = widget.weather;
    final dest = widget.destination;
    final scrubbing = widget.previewProgress != null;
    final scrubbedRemaining = widget.remainingMeters * (1 - _effectiveProgress);
    return Material(
      color: widget.dark ? const Color(0xFF303134) : Colors.white,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Slide selector: the driver picks which ONE to see.
              Row(
                children: [
                  _ModeChip(
                    label: 'Thời gian',
                    icon: Icons.schedule,
                    selected: widget.mode == NavBarMode.time,
                    onTap: () =>
                        widget.onModeChanged?.call(NavBarMode.time),
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'Độ cao',
                    icon: Icons.terrain,
                    selected: widget.mode == NavBarMode.elevation,
                    onTap: () =>
                        widget.onModeChanged?.call(NavBarMode.elevation),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule, size: 16, color: sub),
                  const SizedBox(width: 6),
                  Text(
                    _clock,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: fg,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _Stat(
                    icon: Icons.route_outlined,
                    label: formatDistance(
                      scrubbing ? scrubbedRemaining : widget.remainingMeters,
                    ),
                    color: fg,
                  ),
                  const Spacer(),
                  _Stat(
                    icon: Icons.schedule_outlined,
                    label: minutes < 1 ? '<1\'' : '$minutes phút',
                    color: fg,
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.location_on, size: 16, color: kAppBlue),
                ],
              ),
              // Weather — one clean emoji line (no icon overlap).
              if (w != null &&
                  (w.tempC != null ||
                      w.humidityPct != null ||
                      w.windKmh != null)) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    '${weatherEmoji(w.weatherCode)} '
                    '${w.tempC?.round() ?? '--'}°',
                    if (w.humidityPct != null)
                      '💧 ${w.humidityPct!.round()}%',
                    if (w.windKmh != null) '💨 ${w.windKmh!.round()} km/h',
                    if ((w.precipMm ?? 0) > 0)
                      '🌧 ${w.precipMm!.toStringAsFixed(1)} mm',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: sub,
                  ),
                ),
              ],
              // ONE slide at a time (the driver picks): the elevation
              // (terrain) chart, or the draggable path-time progress.
              if (widget.mode == NavBarMode.elevation &&
                  widget.elevation != null)
                widget.elevation!
              else ...[
                const SizedBox(height: 4),
                // Scrub hint / preview label while dragging.
                if (scrubbing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${(_effectiveProgress * 100).round()}% • còn '
                      '${formatDistance(scrubbedRemaining)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: kAppBlue,
                      ),
                    ),
                  ),
                // Trip progress with start / current car / destination
                // markers — drag to scrub along the path.
                Row(
                  children: [
                    Text(
                      'Bắt đầu',
                      style: TextStyle(fontSize: 11, color: sub),
                    ),
                    const Spacer(),
                    if (dest != null && dest.isNotEmpty)
                      Flexible(
                        child: Text(
                          dest,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: sub),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final p = _effectiveProgress;
                    final trackW = width - 33.0;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (d) =>
                          _scrubAt(d.localPosition.dx, width),
                      onHorizontalDragUpdate: (d) =>
                          _scrubAt(d.localPosition.dx, width),
                      onHorizontalDragEnd: (_) =>
                          widget.onScrubEnd?.call(),
                      child: SizedBox(
                        height: 34,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            // Track + filled progress.
                            Positioned(
                              left: 9,
                              right: 24,
                              top: 13,
                              bottom: 13,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: Stack(
                                  children: [
                                    Container(
                                      color: widget.dark
                                          ? Colors.white24
                                          : const Color(0xFFE0E0E0),
                                    ),
                                    FractionallySizedBox(
                                      widthFactor: p,
                                      child: Container(color: kAppBlue),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Start marker (green dot).
                            Positioned(
                              left: 2,
                              top: 11,
                              child: _Dot(
                                color: const Color(0xFF1E8E3E),
                              ),
                            ),
                            // Destination marker (red flag).
                            Positioned(
                              right: 3,
                              top: 8,
                              child: Icon(
                                Icons.sports_score,
                                size: 16,
                                color: const Color(0xFFC5221F),
                              ),
                            ),
                            // Current car marker (blue dot) at progress.
                            Positioned(
                              left: 9 + p * trackW - 6,
                              top: 10,
                              child: _Dot(
                                color: kAppBlue,
                                size: 12,
                                border: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;


  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color.withValues(alpha: 0.7)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }
}

/// Circular marker used on the trip progress line (start / current car).
class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.size = 10, this.border = false});

  final Color color;
  final double size;
  final bool border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: border ? Border.all(color: Colors.white, width: 2) : null,
      ),
    );
  }
}

/// Small pill used by the slide selector ("Thời gian" / "Độ cao").
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? kAppBlue : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected
                  ? Colors.white
                  : const Color(0xFF5F6368),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected
                    ? Colors.white
                    : const Color(0xFF5F6368),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
