part of 'navigation_page.dart';

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
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            // Every fix (no distance filter) → the nav UI, voice and the clock
            // update as fast as the sensor reports, instead of every 3 m.
            distanceFilter: 0,
          ),
        ).listen(
          (p) {
            // During the simulated drive the SIM owns the position — the real
            // GPS stream (e.g. a stationary phone sitting at the origin) was
            // overwriting `_current` back to the origin and re-running the
            // engine/OSRM-snap, which made the map keep "returning to start".
            if (_simulating) return;
            final pos = LatLng(p.latitude, p.longitude);
            _current = pos;
            _heading = p.heading.isNaN ? null : p.heading;
            if (_engine == null || !_navigating) return;
            // Keep a short trace for online OSRM /match road-snapping.
            _gpsWindow.add(pos);
            if (_gpsWindow.length > 15) _gpsWindow.removeAt(0);
            _lastSpeedMps = p.speed;
            unawaited(_maybeSnapToRoad());
            // Off the route? Re-route once the car stays off-path (>50 m)
            // for 10 s (or immediately when it's clearly far gone, >250 m).
            final off = _engine!.offRouteDistance(pos);
            if (off > 50) {
              final now = DateTime.now();
              final since = _offRouteSince ??= now;
              if (off > 250 ||
                  now.difference(since) >= const Duration(seconds: 10)) {
                _offRouteSince = null;
                _reRoute(pos, speedMps: p.speed);
                return;
              }
            } else {
              _offRouteSince = null;
            }
            _handleNav(pos, speedMps: p.speed);
          },
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

  void _restartGps() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startGps();
    });
  }

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
      final r = await fetchRoadInfo(pos);
      if (!mounted) return;
      setNavState(() => _roadInfo = r);
    } catch (_) {
      // keep the last known road on failure
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
  }

  Future<RoadInfo?> _roadInfoFromGraph(LatLng pos) async {
    final g = await OfflineRouter.instance.roadInfo(pos);
    if (g == null) return null;
    debugPrint('ROAD: graph highway=${g['highway']} maxspeed=${g['maxspeed']}');
    final highway = (g['highway'] ?? '') as String;
    if (highway.isEmpty) return null;
    final (label, fallback) = classInfo(highway);
    // GraphHopper sends Infinity for `maxspeed=none` — treat any non-finite
    // value as "no tagged limit" and fall back to the statutory class default.
    final msRaw = g['maxspeed'];
    final ms = (msRaw is num && msRaw.isFinite) ? msRaw.toInt() : null;
    return RoadInfo(
      name: (g['name'] ?? '') as String,
      highway: highway,
      maxspeed: ms == null ? null : '$ms',
      label: label,
      speedLimit: ms ?? fallback,
    );
  }

  void _logFix(LatLng pos, double speedMps) {
    final t = _trip;
    if (t == null) return;
    t.addFix(pos, speedMps: speedMps, source: _simulating ? 'SIM' : 'GPS');
  }

  void _beginTrip() {
    if (_trip != null) return;
    final dest = _searchCtrl.text.trim();
    _trip = TripLogger(name: dest.isEmpty ? 'Chuyến đi' : dest);
    debugPrint('TRIP: started');
    if (mounted) setNavState(() {});
  }

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
