part of '../navigation_page.dart';

extension _NavGps on _NavigationPageState {
  /// Ensure the location permission is granted. Returns true when the app may
  /// listen for GPS fixes. Handles the two real-world silent killers:
  ///   1. Location SERVICES (the phone's GPS toggle) turned off.
  ///   2. Permission denied "forever" (user picked "don't ask again") — the
  ///      permission dialog never re-appears, so without this the app just
  ///      never gets a fix.
  Future<bool> _requestPermission() async {
    // 1. Location services must be enabled first, or geolocator throws
    //    LocationServiceDisabledException on every stream attempt.
    if (!await Geolocator.isLocationServiceEnabled()) {
      debugPrint('GPS: location service DISABLED on device');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Bật định vị (GPS) trên điện thoại để dẫn đường.'),
              duration: Duration(seconds: 4),
            ),
          );
      }
      return false;
    }

    // 2. Permission. If it was denied "forever", the dialog won't reappear —
    //    send the user to the system settings screen for this app.
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.deniedForever) {
      debugPrint('GPS: permission denied forever — opening app settings');
      await Geolocator.openAppSettings();
      p = await Geolocator.checkPermission();
      return p == LocationPermission.whileInUse ||
          p == LocationPermission.always;
    }
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      debugPrint('GPS: permission denied ($p)');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Cần quyền vị trí để dẫn đường.'),
              duration: Duration(seconds: 3),
            ),
          );
      }
      return false;
    }
    return true;
  }

  void _startGps() {
    _gpsSub?.cancel();
    // Seed the position quickly: a one-shot network-assisted fix (fast, via
    // the fused provider) so the map centers on the user right away instead
    // of waiting for the stream's first satellite fix — which is slow on the
    // itel and is what made the GPS feel laggy at launch. The 1 Hz stream
    // then takes over.
    unawaited(_seedGpsFix());
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            // Every fix (no distance filter) → the nav UI, voice and the clock
            // update as fast as the sensor reports, instead of every 3 m.
            distanceFilter: 0,
          ),
        ).listen(
          _onGpsFix,
          onError: (Object e) {
            // Distinguish the two recoverable real-world conditions so the
            // user gets a message instead of an invisible no-fix state.
            if (e is LocationServiceDisabledException) {
              debugPrint('GPS: location service disabled (stream)');
              if (mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Bật định vị (GPS) trên điện thoại.'),
                      duration: Duration(seconds: 4),
                    ),
                  );
              }
              return; // don't hot-restart into the same wall — wait for toggle
            }
            debugPrint('GPS: stream error: $e — restarting');
            _restartGps();
          },
          onDone: _restartGps,
        );
  }

  /// One-shot fast position seed (network-assisted, ≤ 8 s). Feeds the same
  /// handler as the stream so the map centers + starts tracking immediately.
  Future<void> _seedGpsFix() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
      if (!mounted) return;
      _onGpsFix(p);
    } catch (_) {
      // The stream supplies the first fix when GPS is ready — no-op.
    }
  }

  /// Shared GPS-fix handler (stream fixes + the fast seed). Updates the map,
  /// the engine and (in nav mode) the ETA/voice/clock.
  void _onGpsFix(Position p) {
    final pos = LatLng(p.latitude, p.longitude);
    _current = pos;
    _heading = p.heading.isNaN ? null : p.heading;
    // Browse mode: no engine/route yet — still redraw so the blue
    // current-location marker follows the phone. Without this setState
    // the marker never appeared on the browse map even though the GPS
    // stream was delivering fixes.
    if (_engine == null || !_navigating) {
      // First real fix: pan the browse map to the user so the blue
      // dot is actually on screen (the map starts centred on the
      // default HCMC point, which may be far from the real location —
      // "GPS doesn't work" when the marker was simply off-screen).
      if (!_centeredOnGps && !_navigating) {
        _centeredOnGps = true;
        final cur = _current;
        if (cur != null) _map.move(cur, 16);
      }
      if (mounted) setNavState(() {});
      return;
    }
    // Keep a short trace for online OSRM /match road-snapping.
    _gpsWindow.add(pos);
    if (_gpsWindow.length > 15) _gpsWindow.removeAt(0);
    _lastSpeedMps = p.speed;
    unawaited(_maybeSnapToRoad());
    // Wrong-way (inverse) re-route: driving OPPOSITE to the route direction
    // while staying near the road never trips the >50 m off-route timer (the
    // route line is right there, just the wrong way). Detect it from the
    // travel heading vs the route bearing and re-route after ~3 s.
    _wrongWaySince = _wrongWaySinceOf(pos, p.speed, _wrongWaySince);
    if (_wrongWaySince != null &&
        DateTime.now().difference(_wrongWaySince!) >=
            const Duration(seconds: 3)) {
      _wrongWaySince = null;
      _reRoute(pos, speedMps: p.speed);
      return;
    }
    // Off the route? Re-route once the car stays off-path (>50 m)
    // for 10 s (or immediately when it's clearly far gone, >250 m).
    final off = _engine!.offRouteDistance(pos);
    if (off > 50) {
      final now = DateTime.now();
      final since = _offRouteSince ??= now;
      if (off > 250 || now.difference(since) >= const Duration(seconds: 5)) {
        _offRouteSince = null;
        _reRoute(pos, speedMps: p.speed);
        return;
      }
    } else {
      _offRouteSince = null;
    }
    _handleNav(pos, speedMps: p.speed);
  }

  /// Returns when the car started driving AGAINST the route direction, or
  /// null while it's heading along the route / stationary. Latches while
  /// wrong-way so a single noisy fix can't reset it; resets the moment the
  /// heading realigns with the route (or the car stops).
  DateTime? _wrongWaySinceOf(LatLng pos, double speedMps, DateTime? since) {
    final engine = _engine;
    if (engine == null || !_navigating) return null;
    final prev = _lastFixPos;
    _lastFixPos = pos;
    if (prev == null || speedMps < 1.5) return null;
    // Travel heading from consecutive fixes (robust to GPS-heading noise).
    final travel = const Distance().bearing(prev, pos); // 0..360, 0 = N
    final route = engine.routeBearing();
    // Shortest signed angle between travel and route direction.
    final diff = (travel - route + 540) % 360 - 180;
    if (diff.abs() > 120) return since ?? DateTime.now();
    return null;
  }

  /// Online GPS road-snapping: send the rolling trace to OSRM /match
  /// (throttled to 5 s) to refine the on-route position when online. The
  /// matched point is projected onto the route polyline and only accepted
  /// when it's close — between matches (and fully offline) the always-on
  /// `engine.snapToRoute` projection keeps the car on the road, so the match
  /// never causes the puck to bounce off/on the route (the old flicker).
  Future<void> _maybeSnapToRoad() async {
    if (forceOffline || _gpsWindow.length < 3 || !_navigating) return;
    final now = DateTime.now();
    if (_lastGpsMatch != null &&
        now.difference(_lastGpsMatch!) < const Duration(seconds: 5)) {
      return;
    }
    _lastGpsMatch = now;
    final matched = await fetchAnyMatch(List.of(_gpsWindow));
    if (!mounted || !_navigating || matched == null) return;
    final engine = _engine;
    if (engine == null) return;
    // Only trust the match when it's on/near our route — otherwise it could
    // yank the car onto a parallel road (e.g. after a wrong turn).
    if (engine.offRouteDistance(matched) > 50) return;
    final projected = engine.snapToRoute(matched);
    // Drop a stale result: if the car moved well beyond where the trace was
    // captured while /match was in flight, the next GPS fix re-snaps anyway.
    final cur = _current;
    if (cur != null && distanceMeters(cur, projected) > 30) return;
    _current = projected;
    final nav = engine.update(projected, speedMps: _lastSpeedMps);
    _progress = nav;
    _routeBearing = engine.routeBearing();
    _sendToClock(nav);
    if (mounted) setNavState(() {});
  }

  /// Restart the GPS stream shortly after it ends/errors — some devices
  /// drop the stream, which would silently freeze both the UI updates and
  /// the off-route re-routing.
  void _restartGps() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startGps();
    });
  }

  /// Look up the current road (type + speed limit). Prefers the on-device
  /// GraphHopper graph (instant + offline); falls back to Overpass.
  Future<void> _refreshRoad(LatLng pos) async {
    final now = DateTime.now();
    final last = _lastRoadQuery;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastRoadQuery = now;
    // On-device graph: no network, no server latency.
    if (OfflineRouter.instance.isLoaded) {
      try {
        final r = await _roadInfoFromGraph(pos);
        if (r != null && mounted) {
          setNavState(() => _roadInfo = r);
          return;
        }
      } catch (_) {
        // fall through to Overpass
      }
    }
    if (_roadLoading) return;
    setNavState(() => _roadLoading = true);
    try {
      final r = await fetchRoadInfo(
        pos,
        vehicle: vehicleType,
        override: speedOverride,
      );
      if (!mounted) return;
      setNavState(() => _roadInfo = r);
    } catch (_) {
      // keep the last known road on failure
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
  }

  /// Road info straight from the on-device graph (nearest edge), with the
  /// same Vietnamese statutory defaults as the Overpass path.
  Future<RoadInfo?> _roadInfoFromGraph(LatLng pos) async {
    final g = await OfflineRouter.instance.roadInfo(pos);
    if (g == null) return null;
    debugPrint('ROAD: graph highway=${g['highway']} maxspeed=${g['maxspeed']}');
    final highway = (g['highway'] ?? '') as String;
    if (highway.isEmpty) return null;
    final (label, _) = classInfo(highway);
    // GraphHopper sends Infinity for `maxspeed=none` — treat any non-finite
    // value as "no tagged limit" and fall back to the statutory class default.
    // Also reject implausible finite readings: a mis-decoded max_speed edge
    // once turned a real 50 km/h limit into a bogus "31" (and vice versa).
    // A sane posted limit is 5..200 km/h; anything outside is data noise.
    final msRaw = g['maxspeed'];
    final ms = (msRaw is num && msRaw.isFinite && msRaw >= 5 && msRaw <= 200)
        ? msRaw.toInt()
        : null;
    // Vehicle-aware statutory fallback + optional manual override (settings).
    final limit = speedOverride > 0
        ? speedOverride
        : (ms ?? statutoryLimit(highway, vehicle: vehicleType));
    return RoadInfo(
      name: (g['name'] ?? '') as String,
      highway: highway,
      maxspeed: ms == null ? null : '$ms',
      label: label,
      speedLimit: limit,
    );
  }

  /// Feed the active trip logger (real GPS fixes).
  void _logFix(LatLng pos, double speedMps) {
    final t = _trip;
    if (t == null) return;
    t.addFix(pos, speedMps: speedMps);
  }

  /// Start recording a trip (no-op if one is already active).
  void _beginTrip() {
    if (_trip != null) return;
    final dest = _searchCtrl.text.trim();
    _trip = TripLogger(name: dest.isEmpty ? 'Chuyến đi' : dest);
    debugPrint('TRIP: started');
    if (mounted) setNavState(() {});
  }

  /// Stop recording and save the trip to disk (Google Takeout Records.json).
  Future<void> _finishTrip() async {
    final t = _trip;
    if (t == null) return;
    _trip = null;
    if (mounted) setNavState(() {});
    if (!t.hasEnoughData) {
      debugPrint('TRIP: skipped (only ${t.fixCount} fix)');
      return;
    }
    try {
      final f = await saveTrip(t);
      debugPrint('TRIP: saved ${f.path}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã lưu chuyến đi: ${f.uri.pathSegments.last}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('TRIP: save failed $e');
    }
  }
}
