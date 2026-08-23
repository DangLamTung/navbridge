/// Floating speed-limit / camera widget — Waze-Mod style overlay that floats
/// over ANY other app (Google Maps, Waze, …) while showing the current speed,
/// the real posted limit (bundled offline DATMAP layer) and the next camera.
///
/// Runs in a SEPARATE Flutter engine ([overlayMain]) via
/// `flutter_overlay_window`, so it is fully self-contained: it reads its own
/// GPS and the bundled offline layers — no dependency on the main app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

@pragma('vm:entry-point')
Future<void> overlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OverlayApp());
}

class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});

  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  double _kmh = 0;
  int? _limit;
  int? _camM;
  StreamSubscription<Position>? _sub;

  @override
  void initState() {
    super.initState();
    // Load the offline layers in the background (second engine, same assets).
    unawaited(loadOfflineSpeedLimits());
    unawaited(loadOfflineCameras());
    _startGps();
  }

  Future<void> _startGps() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return; // no location access — show speed 0 / no limit
    }
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen(_onFix);
  }

  Future<void> _onFix(Position p) async {
    final kmh = (p.speed.isNaN ? 0.0 : p.speed) * 3.6;
    final pos = LatLng(p.latitude, p.longitude);
    // Both lookups are local + cached after first use; run them concurrently.
    final (limit, cam) = await (speedLimitAt(pos), _nearestCamera(pos)).wait;
    if (!mounted) return;
    setState(() {
      _kmh = kmh;
      _limit = limit;
      _camM = cam;
    });
  }

  /// Nearest camera within 1 km, in metres (or null when none nearby).
  Future<int?> _nearestCamera(LatLng pos) async {
    final cams = await loadOfflineCameras();
    if (cams.isEmpty) return null;
    const Distance d = Distance();
    var best = double.infinity;
    for (final c in cams) {
      final m = d.as(LengthUnit.Meter, pos, LatLng(c.lat, c.lng));
      if (m < best) best = m;
    }
    return best <= 1000 ? best.round() : null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 136,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xE6000000),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Current speed (big) + unit.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${_kmh.round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 3),
                  child: Text(
                    ' km/h',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Posted limit chip.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _limit == null
                    ? Colors.white24
                    : const Color(0xFFB3261E),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _limit == null ? 'GIỚI HẠN --' : 'GIỚI HẠN $_limit',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_camM != null) ...[
              const SizedBox(height: 4),
              Text(
                '📷 $_camM m',
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
