/// Floating speed-limit / camera widget — Waze-Mod style overlay that floats
/// over ANY other app (Google Maps, Waze, …) while showing the current speed,
/// the real posted limit (bundled offline DATMAP layer) and the next camera / road sign.
///
/// Runs in a SEPARATE Flutter engine ([overlayMain]) via
/// `flutter_overlay_window`, so it is fully self-contained: it reads its own
/// GPS and the bundled offline layers — no dependency on the main app.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/ui/sign_icons.dart';
import 'package:navbridge/ui/widgets.dart';

/// One nearby road-sign chip the floating widget renders (icon + distance).
class _SignChip {
  final String kind;
  final int? value;
  final String? text;
  final int meters;
  const _SignChip(this.kind, this.value, this.text, this.meters);
}

class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});

  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  double _kmh = 0;
  int? _limit;

  /// Last raw fix — used to DERIVE speed from the distance travelled between
  /// fixes when the phone GPS reports speed = 0 (common on cheap devices).
  LatLng? _lastGpsPos;
  DateTime? _lastGpsAt;

  /// Every camera distance (metres) within 600 m, pushed by the main app or
  /// self-computed.
  List<int> _nearCams = const [];

  /// Nearby traffic-sign chips pushed by the main app or self-computed:
  /// every sign within 600 m + zone-boundary signs (khu dân cư / city).
  List<_SignChip> _nearSigns = const [];

  /// Chosen layout id ('dial' | 'vertical' | 'horizontal'), pushed by the main app
  /// (Settings → "Tùy chọn bong bóng nổi"). Default is 'dial'.
  String _layout = 'dial';

  /// Scale multiplier (0.8 to 1.5, default 1.0).
  double _scale = 1.0;

  /// Auto-hidden: the main app pushed "hidden" when the map is zoomed out
  /// below ~z15 or the rain-radar / weather-satellite layer is on.
  bool _hidden = false;

  /// Maneuver state pushed by the main app's nav engine.
  int? _mIconCode;
  int? _mMeters;
  String _mText = '';

  StreamSubscription<Position>? _sub;
  StreamSubscription<dynamic>? _msgSub;
  bool _gpsStarting = false;

  DateTime? _lastMsgAt;
  DateTime? _lastSelfRefresh;

  @override
  void initState() {
    super.initState();
    debugPrint('OVERLAY: app init');
    // Start GPS immediately so speed, limit & camera work standalone over
    // other apps (Google Maps, Waze) even when NavBridge is backgrounded.
    _startGps();

    _msgSub = FlutterOverlayWindow.overlayListener.listen((msg) {
      final m = msg is Map ? msg : const <dynamic, dynamic>{};
      debugPrint(
        'OVERLAY: msg hidden=${m['hidden']} m=${m['mMeters']} '
        'limit=${m['limit']} cams=${m['cameras']} kmh=${m['kmh']} layout=${m['layout']} scale=${m['scale']}',
      );
      if (!mounted) return;
      _lastMsgAt = DateTime.now();
      setState(() {
        _hidden = m['hidden'] == true;
        _mIconCode = m['mIcon'] as int?;
        _mMeters = m['mMeters'] as int?;
        _mText = (m['mText'] ?? '') as String;
        _limit = m['limit'] as int?;
        final rawCams = m['cameras'];
        if (rawCams is List) {
          _nearCams = [
            for (final e in rawCams)
              if (e is num) e.toInt(),
          ];
        }
        final rawSigns = m['signs'];
        if (rawSigns is List) {
          _nearSigns = [
            for (final e in rawSigns)
              if (e is Map)
                _SignChip(
                  (e['k'] as String?) ?? 'stop',
                  e['v'] as int?,
                  e['t'] as String?,
                  (e['m'] as num?)?.toInt() ?? 0,
                ),
          ];
        }

        if (m['kmh'] != null && m['kmh'] is num) {
          // Same exponential smoothing as the self-GPS path so the pushed
          // (outlier-gated / ESP BLE) speed doesn't jump on every update.
          final kmh = (m['kmh'] as num).toDouble();
          final alpha = kmh > _kmh ? 0.5 : 0.3;
          _kmh += alpha * (kmh - _kmh);
        }
        if (_hidden) {
          _nearCams = const [];
          _nearSigns = const [];
        }
        final l = m['layout'];
        if (l is String && l.isNotEmpty) {
          _layout = switch (l) {
            'horizontal' || 'pill' => 'horizontal',
            'vertical' => 'vertical',
            _ => 'dial',
          };
        }
        final s = m['scale'];
        if (s is num) _scale = s.toDouble().clamp(0.8, 2.0);
      });
      if (_hidden) {
        _stopGps();
      } else {
        _startGps();
      }
    });
  }

  Future<void> _startGps() async {
    if (_sub != null || _gpsStarting) return;
    if (!await FlutterOverlayWindow.isPermissionGranted()) return;
    if (!await Geolocator.isLocationServiceEnabled()) return;
    _gpsStarting = true;
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          // 0 = every fix (the main nav app uses 0 too). A non-zero distance
          // filter throttled updates to every 3 m — at city speed the widget
          // looked frozen/stale.
          distanceFilter: 0,
        ),
      ).listen(_onFix);
    } finally {
      _gpsStarting = false;
    }
  }

  void _stopGps() {
    _sub?.cancel();
    _sub = null;
  }

  void _onFix(Position p) {
    if (!mounted) return;
    final pos = LatLng(p.latitude, p.longitude);
    // Raw GPS speed (m/s); NaN → 0.
    var spd = p.speed.isNaN ? 0.0 : p.speed;
    // Cheap phones often report speed = 0: derive it from the distance
    // travelled between consecutive fixes (same trick as the ESP frame path
    // in the main nav app).
    final now = DateTime.now();
    final lastPos = _lastGpsPos;
    final lastAt = _lastGpsAt;
    _lastGpsPos = pos;
    _lastGpsAt = now;
    if (spd < 0.5 && lastPos != null && lastAt != null) {
      final dt = now.difference(lastAt).inMilliseconds / 1000.0;
      if (dt > 0.4 && dt < 5) {
        final derived =
            const Distance().as(LengthUnit.Meter, lastPos, pos) / dt;
        // Trust the derived speed only when plausible (> ~5 km/h); below that
        // GPS jitter makes position deltas meaningless.
        if (derived > 1.4) spd = derived;
      }
    }
    final kmh = spd * 3.6;
    // Prefer the MAIN app's pushed speed (outlier-gated, ESP BLE when the
    // receiver is active) whenever it is alive (<2 s since its last message);
    // otherwise this raw self-GPS speed would overwrite it every fix and the
    // bubble would flicker between the two sources.
    final lastMsg = _lastMsgAt;
    final msgFresh =
        lastMsg != null &&
        DateTime.now().difference(lastMsg) < const Duration(seconds: 2);
    if (!msgFresh) {
      // Exponential smoothing so the dial/card doesn't jump on every noisy
      // fix (respond a little faster when accelerating).
      final alpha = kmh > _kmh ? 0.5 : 0.3;
      _kmh += alpha * (kmh - _kmh);
      setState(() {});
    }
    unawaited(_selfContainedAhead(pos));
  }

  Future<void> _selfContainedAhead(LatLng pos) async {
    final lastMsg = _lastMsgAt;
    if (lastMsg != null &&
        DateTime.now().difference(lastMsg) < const Duration(seconds: 3)) {
      return;
    }
    final now = DateTime.now();
    if (_lastSelfRefresh != null &&
        now.difference(_lastSelfRefresh!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSelfRefresh = now;
    try {
      final l = await speedLimitAt(pos);
      if (mounted && l != null && l != _limit) setState(() => _limit = l);
    } catch (_) {}
    try {
      final cams = await camerasForWidgetChips(pos, maxDistM: 600);
      if (!mounted) return;
      setState(() => _nearCams = cams);
    } catch (_) {}
    try {
      // The widget shows just the SINGLE nearest / most important sign.
      final chips = await signsForWidgetChips(pos, maxDistM: 800, max: 1);
      if (!mounted) return;
      setState(() {
        _nearSigns = [
          for (final (s, m) in chips) _SignChip(s.kind.key, s.value, s.name, m),
        ];
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();

    final isDial = _layout == 'dial' || _layout == 'speedometer';
    final isHorizontal = _layout == 'horizontal';

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.topRight,
          child: Transform.scale(
            scale: _scale,
            alignment: Alignment.topRight,
            child: isDial
                ? _buildDial()
                : Container(
                    decoration: BoxDecoration(
                      color: const Color(0xF216181F),
                      borderRadius: BorderRadius.circular(
                        isHorizontal ? 22 : 28,
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 1.0,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: isHorizontal ? _buildHorizontal() : _buildVertical(),
                  ),
          ),
        ),
      ),
    );
  }

  /// Layout "Đồng hồ tốc độ" / "Bong bóng tròn" (matching the reference image):
  /// Round dark speedometer gauge with perimeter tick marks, large live speed + km/h,
  /// top-right overlapping P.127 speed limit sign, and optional nearby sign alert.
  Widget _buildDial() {
    final speeding = _limit != null && _limit! > 0 && _kmh > _limit!;
    final hasCamera = _nearCams.isNotEmpty;
    final hasSign = _nearSigns.isNotEmpty;
    const dialSize = 104.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Main Dial with Overlapping Speed Limit Sign
        SizedBox(
          width: dialSize + 22,
          height: dialSize + 18,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Circular Speedometer Dial
              Positioned(
                left: 0,
                bottom: 0,
                child: SizedBox(
                  width: dialSize,
                  height: dialSize,
                  child: CustomPaint(
                    painter: _DialPainter(
                      kmh: _kmh,
                      limit: _limit,
                      speeding: speeding,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 4),
                          Text(
                            '${_kmh.round()}',
                            style: TextStyle(
                              color: speeding
                                  ? const Color(0xFFFF5252)
                                  : Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'km/h',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Overlapping Speed Limit Sign (P.127) at Top-Right
              Positioned(top: 0, right: 0, child: _limitBadgeCircle(size: 46)),
            ],
          ),
        ),

        // Nearby Camera / Road Sign Alert Pill below Dial
        if (hasCamera || hasSign) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
            decoration: BoxDecoration(
              color: const Color(0xF2181A22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 0.8,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (hasCamera) _cameraChips(max: 2),
                if (hasSign) ...[
                  if (hasCamera) const SizedBox(height: 3),
                  _signChips(max: 3),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Circular Speed Limit Sign with coral red ring and crisp black number
  Widget _limitBadgeCircle({double size = 46}) {
    final l = _limit;
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

  /// Layout "Nằm dọc" (Vertical):
  /// Maneuver (Arrow + Dist + Street) ── Limit Sign ── Speed km/h ── Camera / Alert.
  Widget _buildVertical() {
    final speeding = _limit != null && _limit! > 0 && _kmh > _limit!;
    final hasManeuver = _mMeters != null && _mMeters! > 0;
    final hasCamera = _nearCams.isNotEmpty;
    final hasSign = _nearSigns.isNotEmpty;

    return Container(
      width: 82,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Section 1: Next Maneuver (when navigating)
          if (hasManeuver) ...[
            Icon(maneuverIcon(_mIconCode ?? 0), color: Colors.white, size: 32),
            const SizedBox(height: 2),
            Text(
              _fmtDist(_mMeters!),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                height: 1.1,
              ),
            ),
            if (_mText.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                _mText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            _divider(),
          ],

          // Section 2: Speed Limit Sign (P.127)
          _limitBadge(size: 52),
          const SizedBox(height: 6),

          // Section 3: Current Speed Monitor
          Text(
            '${_kmh.round()}',
            style: TextStyle(
              color: speeding ? const Color(0xFFFF5252) : Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w900,
              height: 1.0,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'km/h',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),

          // Section 4: Upcoming Camera / Sign Alert
          if (hasCamera || hasSign) ...[
            _divider(),
            if (hasCamera) ...[
              _cameraChips(max: 2),
              if (hasSign) const SizedBox(height: 3),
            ],
            if (hasSign) ...[_signChips(max: 2)],
          ],
        ],
      ),
    );
  }

  /// Layout "Nằm ngang" (Horizontal):
  /// Speed km/h │ Speed Limit Sign │ Camera / Maneuver
  Widget _buildHorizontal() {
    final speeding = _limit != null && _limit! > 0 && _kmh > _limit!;
    final hasCamera = _nearCams.isNotEmpty;
    final hasSign = _nearSigns.isNotEmpty;
    final hasManeuver = _mMeters != null && _mMeters! > 0;

    return Container(
      width: 216,
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: Speed Monitor
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${_kmh.round()}',
                  style: TextStyle(
                    color: speeding ? const Color(0xFFFF5252) : Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'km/h',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),

          // Center: Speed Limit Sign
          _limitBadge(size: 48),

          // Right: Nearby Road Sign → Next Turn → Camera → GPS fallback.
          // The driver's priority is the upcoming SIGN / TURN, so those come
          // before the camera alert (the user: "right shows camera but should
          // be the sign / turn").
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (hasSign) ...[
                  _signChips(max: 1),
                ] else if (hasManeuver) ...[
                  Icon(
                    maneuverIcon(_mIconCode ?? 0),
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtDist(_mMeters!),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ] else if (hasCamera) ...[
                  _cameraChips(max: 1),
                ] else ...[
                  Icon(
                    Icons.shield_outlined,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 20,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'GPS',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compact stack of the nearby camera chips (icon + distance) — every
  /// camera within 600 m. Shows up to [max], then a "+N".
  Widget _cameraChips({int max = 3}) {
    final cams = _nearCams.take(max).toList();
    final more = _nearCams.length - cams.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < cams.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/waze/icon_alerter_cam_speed.png',
                width: 18,
                height: 18,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.videocam_rounded,
                  color: Colors.amberAccent,
                  size: 16,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _fmtDist(cams[i]),
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
        if (more > 0) ...[
          const SizedBox(height: 1),
          Text(
            '+$more',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  /// Compact stack of the nearby sign chips (icon + distance) — every sign
  /// within 600 m + zone-boundary signs. Shows up to [max], then a "+N".
  Widget _signChips({int max = 3}) {
    final chips = _nearSigns.take(max).toList();
    final more = _nearSigns.length - chips.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _miniSignIcon(chips[i].kind, chips[i].value, size: 18),
              const SizedBox(width: 4),
              Text(
                _fmtDist(chips[i].meters),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
        if (more > 0) ...[
          const SizedBox(height: 1),
          Text(
            '+$more',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  Widget _miniSignIcon(String? kind, int? value, {double size = 22}) {
    // Reuse the SAME Vietnamese QCVN 41 sign painters as the navigation map
    // (lib/ui/sign_icons.dart) so the overlay shows the identical real signs —
    // R.301 speed circle, red-ring prohibitions, blue mandatory arrows, STOP
    // octagon, W.205 nhường đường… — never a generic warning triangle.
    if (kind == null) {
      return const Icon(
        Icons.warning_amber_rounded,
        color: Colors.amberAccent,
        size: 18,
      );
    }
    return SignIcon(kind: RoadSignKind.fromKey(kind), value: value, size: size);
  }

  Widget _divider() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      color: Colors.white.withValues(alpha: 0.12),
    );
  }

  /// Compact distance format: "647 m" / "1.0km"
  String _fmtDist(int m) {
    if (m >= 1000) {
      final km = m / 1000.0;
      return '${km.toStringAsFixed(1)}km';
    }
    return '$m m';
  }

  /// Vietnamese R.301 circular speed-limit sign badge (QCVN 41:2019):
  /// Pure white circle, thick red ring border, crisp black number.
  /// ALWAYS DRAWN — never a bitmap asset — so it is exactly the Việt Nam sign.
  /// The old `assets/waze/vn/*.png` were Waze-style speed signs, not the
  /// Vietnamese R.301 (that's the "sign icon is wrong" report).
  Widget _limitBadge({double size = 50}) {
    final l = _limit;
    if (l != null && l > 0) return _p127Fallback(l, size: size);
    return _p127Placeholder(size: size);
  }

  Widget _p127Fallback(int l, {required double size}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFFF5252), width: size * 0.12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '$l',
        style: TextStyle(
          color: Colors.black,
          fontSize: size * (l >= 100 ? 0.38 : 0.44),
          fontWeight: FontWeight.w900,
          height: 1.0,
          letterSpacing: -0.5,
        ),
      ),
    );
  }

  Widget _p127Placeholder({required double size}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFFF5252), width: size * 0.12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '--',
        style: TextStyle(
          color: Colors.black54,
          fontSize: size * 0.40,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Paints the round speedometer gauge used by the "Đồng hồ tốc độ" layout:
/// dark circular face, orange/red progressive perimeter tick-marks, matching the reference image.
class _DialPainter extends CustomPainter {
  final double kmh;
  final int? limit;
  final bool speeding;

  const _DialPainter({required this.kmh, this.limit, required this.speeding});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Dark circular gauge background
    final bgPaint = Paint()
      ..color = const Color(0xFF2C3238)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(c, r * 0.96, bgPaint);

    // Subtle outer ring
    final ringPaint = Paint()
      ..color = const Color(0xFF23282E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(c, r * 0.96, ringPaint);

    // Segmented ticks around circumference
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
          final progress = i / totalTicks;
          tickColor = Color.lerp(
            const Color(0xFFFF9500),
            const Color(0xFFFF3B30),
            progress,
          )!;
        }
      } else {
        tickColor = const Color(0xFF434B54);
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
  bool shouldRepaint(covariant _DialPainter old) =>
      old.kmh != kmh || old.limit != limit || old.speeding != speeding;
}
