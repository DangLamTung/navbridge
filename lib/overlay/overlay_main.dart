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
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_router.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/ui/limit_source.dart';
import 'package:navbridge/ui/sign_icons.dart';
import 'package:navbridge/ui/speed_dial.dart' show SpeedDialPainter;
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

  /// Short badge for WHERE [_limit] came from ('WAZE' / 'SIGN' / 'CITY' …),
  /// pushed by the main app and drawn under the dial so the number can be
  /// judged at a glance instead of guessed.
  String? _limitSrc;

  /// The configured vehicle ('car' | 'motorbike' | 'truck'), loaded from
  /// settings so the standalone floating widget caps the posted limit to the
  /// vehicle's statutory class default — the raw DATMAP/Waze/VietMap value is
  /// a CAR limit, so a motorbike must never show 80 km/h.
  String _vehicle = 'motorbike';

  /// Last raw fix — used to DERIVE speed from the distance travelled between
  /// fixes when the phone GPS reports speed = 0 (common on cheap devices).
  LatLng? _lastGpsPos;
  DateTime? _lastGpsAt;

  /// Every camera distance (metres) within 600 m, pushed by the main app or
  /// self-computed.
  List<int> _nearCams = const [];

  /// Nearby traffic-sign chips pushed by the main app or self-computed:
  /// every sign within 600 m.
  List<_SignChip> _nearSigns = const [];

  /// Chosen layout id ('dial' | 'vertical' | 'horizontal'), pushed by the main app
  /// (Settings → "Tùy chọn bong bóng nổi"). Default is 'dial'.
  String _layout = 'dial';

  /// Scale multiplier (0.8 to 1.5, default 1.0).
  double _scale = 1.0;

  /// Auto-hidden: the main app pushed "hidden" when the map is zoomed out
  /// below ~z15 or the rain-radar / weather-satellite layer is on.
  bool _hidden = false;

  /// True while the MAIN app is actively navigating. When set, the main app's
  /// turn-by-turn voice is already speaking, so the overlay must NOT announce
  /// cameras/signs itself (two TTS engines talking at once = overlap). The
  /// overlay only self-announces when it's standalone (main app backgrounded).
  bool _navigating = false;

  /// Maneuver state pushed by the main app's nav engine.
  int? _mIconCode;
  int? _mMeters;
  String _mText = '';

  StreamSubscription<Position>? _sub;
  StreamSubscription<dynamic>? _msgSub;
  bool _gpsStarting = false;

  DateTime? _lastMsgAt;
  DateTime? _lastSelfRefresh;

  /// TTS for camera / sign announcements while the floating widget is shown.
  final FlutterTts _tts = FlutterTts();
  DateTime? _lastCamAnnounce;
  DateTime? _lastSignAnnounce;
  String _lastSignKind = '';

  @override
  void initState() {
    super.initState();
    debugPrint('OVERLAY: app init');
    // Start GPS immediately so speed, limit & camera work standalone over
    // other apps (Google Maps, Waze) even when NavBridge is backgrounded.
    _startGps();
    _tts.setLanguage('vi-VN');
    _tts.setSpeechRate(0.48);
    // Load the vehicle type for the speed-limit cap (best-effort; the widget
    // also receives the main app's vehicle-capped limit via [syncOverlayState]
    // while navigating, so this only matters standalone over another app).
    loadSettings()
        .then((s) {
          if (mounted) setState(() => _vehicle = s.vehicleType);
        })
        .catchError((_) {});

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
        _navigating = m['navigating'] == true;
        _mIconCode = m['mIcon'] as int?;
        _mMeters = m['mMeters'] as int?;
        _mText = (m['mText'] ?? '') as String;
        _limit = m['limit'] as int?;
        final rawSrc = m['lsrc'];
        if (rawSrc is String) _limitSrc = rawSrc;
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
      _announceNearby();
    });
  }

  /// Speak the nearest camera / sign once, so the floating widget announces
  /// what's ahead (Waze-Mod style) even when NavBridge is backgrounded.
  ///
  /// The overlay must NOT speak while the MAIN app is actively navigating —
  /// the main app's turn-by-turn voice is already announcing cameras/signs,
  /// so two TTS engines would talk over each other. Only self-announce when
  /// the widget is standalone (main app backgrounded / not navigating).
  void _announceNearby() {
    if (_hidden || _navigating) return;
    // Self-announce only when the main-app push is stale (>2 s) — i.e. the
    // widget is truly standalone over another app, not fighting the push.
    final lastMsg = _lastMsgAt;
    if (lastMsg != null &&
        DateTime.now().difference(lastMsg) < const Duration(seconds: 2)) {
      return;
    }
    final now = DateTime.now();
    // Camera: nearest within 300 m, announced once per camera zone.
    if (_nearCams.isNotEmpty) {
      final nearest = _nearCams.reduce(math.min);
      if (nearest <= 300) {
        if (_lastCamAnnounce == null ||
            now.difference(_lastCamAnnounce!) > const Duration(seconds: 45)) {
          _lastCamAnnounce = now;
          _tts.speak('Camera phía trước $nearest mét');
        }
      } else if (nearest > 450) {
        _lastCamAnnounce = null;
      }
    }
    // Sign: nearest important sign within 300 m.
    if (_nearSigns.isNotEmpty) {
      final sorted = [..._nearSigns]
        ..sort((a, b) => a.meters.compareTo(b.meters));
      final s = sorted.first;
      if (s.meters <= 300) {
        if (s.kind != _lastSignKind ||
            _lastSignAnnounce == null ||
            now.difference(_lastSignAnnounce!) > const Duration(seconds: 45)) {
          _lastSignKind = s.kind;
          _lastSignAnnounce = now;
          _tts.speak(_signSpeech(s));
        }
      } else if (s.meters > 450) {
        _lastSignAnnounce = null;
        _lastSignKind = '';
      }
    }
  }

  String _signSpeech(_SignChip s) {
    final label = RoadSignKind.fromKey(s.kind).label;
    return '$label phía trước ${s.meters} mét';
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
      // The widget must keep working while the user is in ANOTHER app (its
      // main use is floating over Google Maps / Waze), so background location
      // access is needed. If the OS grants "always" keep it; if it only gives
      // whileInUse, an in-use fix is still better than nothing.
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
    final now = DateTime.now();
    // The main app pushes limit/cameras/signs at ~1 Hz WHILE FOREGROUND, so
    // trust its (vehicle-capped, route-aware) values when fresh. But once the
    // push goes stale (app backgrounded — the widget's main use over Google
    // Maps/Waze), the overlay MUST recompute from its own GPS so speed, limit,
    // cameras and place keep updating. A hard "return if fresh" left the
    // widget frozen whenever a push was 1-2 s old. Refresh every ~1 s to
    // match the GPS cadence (the user wants the widget to update at 1 s too).
    if (_lastSelfRefresh != null &&
        now.difference(_lastSelfRefresh!) < const Duration(seconds: 1)) {
      return;
    }
    _lastSelfRefresh = now;
    // The main app pushes its own street-matched, vehicle-capped speed + limit
    // at ~1 Hz. Trust those values (they're outlier-gated / route-aware, and
    // matched to the real road the car is on) instead of recomputing our own
    // point-based limit here — only self-compute once the push goes stale
    // (app backgrounded, the widget's main use over Google Maps / Waze).
    final pushedFresh =
        _lastMsgAt != null &&
        now.difference(_lastMsgAt!) < const Duration(seconds: 2);
    if (pushedFresh) return;
    try {
      // Road class + form tags for the statutory fallback (all of it comes from
      // the same on-device graph the app uses).
      String hw = 'unclassified';
      var roadName = '';
      bool? oneway;
      int? lanes;
      var divided = false;
      try {
        final g = await OfflineRouter.instance.roadInfo(pos);
        final gh = (g?['highway'] ?? '') as String;
        if (gh.isNotEmpty) hw = gh;
        roadName = (g?['name'] ?? '') as String;
        oneway = parseOneway(g?['oneway'] as String?);
        lanes = parseLanes(g?['lanes']);
        divided = g?['divided'] == true;
      } catch (_) {}

      final posted = await speedLimitAt(pos);
      // Which layer answered, before the fallback overwrites the variable.
      final postedLayer = posted != null ? lastLimitLayer() : null;
      // ONE decision, shared with the app (roadInfoFromRoad + applyPostedLayer):
      // the posted layer wins when it answered, otherwise the road's own class
      // table applies with the built-up rule on top. This widget used to
      // re-derive the fallback itself and kept the RURAL class default in town
      // (60 on a 2-lane city street) while the app showed 50.
      final road = roadInfoFromRoad(
        name: roadName,
        highway: hw,
        vehicle: _vehicle,
        oneway: oneway,
        lanes: lanes,
        divided: divided,
        urban: await builtUpRuleApplies(pos, hasPosted: posted != null),
      );
      final decided = (posted != null && posted > 0)
          ? applyPostedLayer(
              road,
              kmh: posted,
              vehicle: _vehicle,
              layerSrc: postedLayer ?? srcSegment,
            )
          : road;
      final limit = decided.speedLimit;
      if (mounted && limit > 0 && limit != _limit) {
        setState(() => _limit = limit);
      }
      if (mounted) {
        // Self-computed path (no main app pushing): name the source with the
        // SAME mapper the app uses, so the two badges can never disagree.
        final label = limitSourceLabel(decided.src);
        if (label != _limitSrc) setState(() => _limitSrc = label);
      }
    } catch (_) {}
    try {
      final cams = await camerasForWidgetChips(pos, maxDistM: 600);
      if (!mounted) return;
      setState(() => _nearCams = cams);
      _announceNearby();
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
      _announceNearby();
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

              // Data-source badge (which layer the limit came from), tucked
              // under the dial where the wrong street name used to sit.
              if (_limitSrc != null && _limitSrc!.isNotEmpty)
                Positioned(
                  left: 0,
                  bottom: -2,
                  width: dialSize,
                  child: Text(
                    _limitSrc!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFB0BEC5),
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      height: 1.0,
                    ),
                  ),
                ),
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
  /// within 600 m. Shows up to [max], then a "+N".
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
/// dark circular face, orange/red progressive perimeter tick-marks, matching
/// the reference image.
///
/// The implementation lives in `ui/speed_dial.dart` ([SpeedDialPainter]) so the
/// NAV screen can offer the same gauge as a display style — one painter, no
/// drift between the widget and the nav chip.
class _DialPainter extends SpeedDialPainter {
  const _DialPainter({
    required super.kmh,
    super.limit,
    required super.speeding,
  });
}
