part of 'navigation_page.dart';

extension _NavNavigation on _NavigationPageState {

  Future<void> _maybeRunNavTest() async {
    const long = bool.fromEnvironment('NAVTEST_LONG');
    const mountain = bool.fromEnvironment('NAVTEST_MOUNTAIN');
    const offline = bool.fromEnvironment('NAVTEST_OFFLINE');
    if (!const bool.fromEnvironment('NAVTEST') &&
        !long &&
        !mountain &&
        !offline) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    debugPrint(
      'NAVTEST: building route to '
      '${long ? 'Hà Nội (~1600km)' : mountain ? 'Đà Lạt (terrain)' : 'Chợ Bến Thành'}'
      '${offline ? ' (OFFLINE)' : ''}',
    );
    setNavState(() {
      dataSource = 'osm'; // public OSRM routing (works from the emulator)
      if (offline) {
        // 100% on-device: offline GraphHopper graph + bundled HCMC pmtiles.
        forceOffline = true;
        _current = const LatLng(10.8231, 106.6297);
        _origin = const LatLng(10.8231, 106.6297);
      } else if (mountain) {
        // Start on Lang Biang and drive down into Đà Lạt city, with 3D
        // terrain + tilt enabled so the hillshading is visible.
        _terrain3d = true;
        _tilt3d = true;
        _current = const LatLng(11.9520, 108.4420);
        _origin = const LatLng(11.9520, 108.4420);
      }
      _stops.add(
        long
            ? TripStop(name: 'Hà Nội', lat: 21.0285, lng: 105.8542)
            : mountain
                ? TripStop(name: 'Đà Lạt', lat: 11.9404, lng: 108.4583)
                : TripStop(name: 'Chợ Bến Thành', lat: 10.7725, lng: 106.6980),
      );
    });
    try {
      await _buildPlanRoute();
    } catch (e) {
      debugPrint('NAVTEST: plan failed: $e');
      return;
    }
    if (!mounted) return;
    _toggleSimulation();
    debugPrint(
      'NAVTEST: SIM drive started '
      '(${long ? 'LONG' : mountain ? 'MOUNTAIN' : offline ? 'OFFLINE' : 'short + re-route'})',
    );
    if (!long && !mountain && !offline) {
      // 20 s in, drive off-route to exercise the re-route path (expect
      // `SIM: REROUTE` + a fresh `PLAN: BUILD ok`).
      Future<void>.delayed(const Duration(seconds: 20), () {
        if (!mounted || !_simulating) return;
        debugPrint('NAVTEST: going off-route to test re-routing');
        _simOffRoute = true;
      });
    }
  }

  void _handleNav(LatLng pos, {required double speedMps}) {
    // Off-route re-route uses the RAW fix — a snapped point is always on the
    // route, so it could never trigger. Stays >50 m off-path for 10 s, or
    // re-routes immediately when clearly far gone.
    final off = _engine!.offRouteDistance(pos);
    if (off > 50) {
      final now = DateTime.now();
      final since = _offRouteSince ??= now;
      if (off > 250 || now.difference(since) >= const Duration(seconds: 10)) {
        _offRouteSince = null;
        unawaited(_reRoute(pos, speedMps: speedMps));
        return;
      }
    } else {
      _offRouteSince = null;
    }
    // Project the raw fix onto the route polyline so the car RIDES the road:
    // the puck, the camera bearing and the turn meter all stay stable even
    // when the real GPS fix wanders a few meters off the road (this is what
    // kept the arrow flickering — the raw fix fed the nearest-vertex bearing).
    final snapped = _engine!.snapToRoute(pos);
    _current = snapped; // keep the vector map + POI search on the route
    final nav = _engine!.update(snapped, speedMps: speedMps);
    _progress = nav;
    // Consume the driven part of the route (the map only draws from here on).
    _routeStartIndex = _engine!.snappedSegmentIndex;
    // Smoothed route-ahead bearing for the arrow/camera (flicker-free).
    _routeBearing = _engine!.routeBearing();
    debugPrint(
      'SIM: handleNav dist=$_simDist meter=${nav.meter} icon=${nav.iconCode} '
      'start=$_routeStartIndex',
    );
    // SIM verification aid: show how much the road-snapping corrected the raw
    // (noisy, in NAVTEST) fix back onto the route, plus the smoothed route
    // bearing that drives the arrow/camera (must be stable — no flipping).
    if (_simulating) {
      debugPrint(
        'NAVTEST: gps raw=${pos.latitude.toStringAsFixed(5)},'
        '${pos.longitude.toStringAsFixed(5)} → '
        'snapped=${snapped.latitude.toStringAsFixed(5)},'
        '${snapped.longitude.toStringAsFixed(5)} '
        'correct=${distanceMeters(pos, snapped).toStringAsFixed(1)}m '
        'bearing=${_routeBearing.toStringAsFixed(1)}',
      );
    }
    _sendToClock(nav);
    _maybeSpeakManeuver(nav);
    _refreshRoad(snapped);
    _logFix(pos, speedMps);
    _map.move(snapped, 17);
    if (mounted) setNavState(() {});
  }

  Future<void> _reRoute(LatLng from, {double speedMps = 0}) async {
    // Cooldown: don't re-route-spam while GPS is jittery off-route.
    final now = DateTime.now();
    if (_lastReRoute != null &&
        now.difference(_lastReRoute!) < const Duration(seconds: 10)) {
      return;
    }
    _lastReRoute = now;
    debugPrint('SIM: REROUTE from=$from');
    final dest = _destination;
    if (dest == null) return;
    try {
      final route = await fetchAnyRoute(
        [from, dest],
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      if (!mounted || _destination == null) return;
      setNavState(() {
        _route = route;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _showSteps = false;
        _routeBearing = 0;
        _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      });
      // Snap straight into the new route (updates distance, icon, clock,
      // voice) instead of waiting for the next GPS fix.
      _handleNav(from, speedMps: speedMps);
    } catch (_) {
      // keep the old route on failure
    }
  }

  void _toggleSimulation() {
    debugPrint('SIM: toggle called, was _simulating=$_simulating');
    if (_simulating) {
      _simTimer?.cancel();
      setNavState(() => _simulating = false);
      return;
    }
    final engine = _engine;
    if (engine == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Hãy chọn địa điểm trước.')));
      return;
    }
    setNavState(() {
      _navigating = true; // show the nav card
      _simulating = true;
      _simDist = engine.currentCumulative;
    });
    _startWeather(); // same as a real navigation start (bottom-bar temp)
    unawaited(WakelockPlus.enable()); // keep the screen on while navigating
    _beginTrip(); // auto-record the (simulated) drive
    // ~8 m per 500 ms ≈ 58 km/h
    debugPrint('SIM: starting timer, simDist=$_simDist');
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final e = _engine;
      if (e == null) return;
      _simDist += 8;
      var pos = e.positionAtDistance(_simDist);
      if (_simOffRoute) {
        // Drive ~300 m east of the route — far enough (>250 m) to trigger an
        // immediate off-route re-route so NAVTEST can verify it.
        pos = LatLng(pos.latitude, pos.longitude + 0.004);
      }
      if (const bool.fromEnvironment('NAVTEST')) {
        // Inject realistic GPS error so the road-snapping (`snapToRoute`) is
        // exercised — the raw fix lands a few metres off the road and is
        // pulled back onto the polyline (see the `NAVTEST: gps` log).
        pos = _addGpsNoise(pos);
      }
      _handleNav(pos, speedMps: 16);
      if (_simDist % 80 == 0) {
        debugPrint('SIM: tick dist=$_simDist offRoute=$_simOffRoute');
      }
    });
  }

  LatLng _addGpsNoise(LatLng p) {
    final r = Random();
    final crossMeters = (r.nextDouble() * 2 - 1) * 12.0;
    return _engine!.lateralOffset(p, crossMeters);
  }
  Future<void> _sendToClock(NavProgress nav) async {
    if (!_clock.isConnected) return;
    await _clock.sendNavFrame(
      meter: nav.meter,
      iconCode: nav.iconCode,
      hour: nav.etaHour,
      minute: nav.etaMinute,
      text: nav.text,
    );
  }

  Future<void> _startNavigation() async {
    debugPrint('SIM: START navigation pressed');
    final engine = _engine;
    if (engine == null) return;
    final origin = await _resolveOrigin();
    if (origin == null) return;
    setNavState(() => _navigating = true);
    _beginTrip(); // auto-record the real drive
    final nav = engine.update(origin, speedMps: 0);
    _progress = nav;
    _logFix(origin, 0);
    _sendToClock(nav);
    _spokenFar = false;
    _spokenNear = false;
    _spokenFinal = false;
    _arrivedSpoken = false;
    _lastManeuverSig = null;
    _offRouteSince = null;
    _routeStartIndex = 0; // full route at the start of navigation
    _gpsWindow.clear();
    _startWeather();
    unawaited(WakelockPlus.enable()); // keep the screen on while navigating
    if (mounted) setNavState(() {});
  }
  Future<void> _exitNavigation() async {
    debugPrint('SIM: EXIT navigation called');
    _simTimer?.cancel();
    setNavState(() {
      _navigating = false;
      _simulating = false;
      _route = null;
      _engine = null;
      _destination = null;
      _progress = null;
      _routeStartIndex = 0;
      _roadInfo = null;
      _stops.clear();
      _showSteps = false;
      _alternativeRoutes = [];
      _selectedRoute = 0;
      _planPoints = [];
      _dragHandles = [];
      _elevation = null;
      _pois = [];
      _poiType = null;
      _selectedPoi = null;
    });
    _offRouteSince = null;
    _gpsWindow.clear();
    _stopWeather();
    unawaited(WakelockPlus.disable()); // screen can sleep again
    await _finishTrip(); // save the recorded trip
  }

  Future<void> _toggleClock() async {
    if (_clock.isConnected) {
      await _clock.disconnect();
      if (mounted) setNavState(() => _clockStatus = 'off');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DevicePickerSheet(clock: _clock, onPicked: _connectTo),
    );
  }
  Future<void> _connectTo(String mac) async {
    if (!mounted) return;
    setNavState(() => _clockStatus = 'connecting');
    try {
      await _clock.connect(mac: mac);
      if (mounted) setNavState(() => _clockStatus = 'connected');
    } catch (e) {
      if (mounted) {
        setNavState(() => _clockStatus = 'off');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('BLE: $e')));
      }
    }
  }
}
