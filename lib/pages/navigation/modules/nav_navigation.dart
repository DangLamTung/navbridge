part of '../navigation_page.dart';

extension _NavNavigation on _NavigationPageState {
  /// Shared by real GPS: snap the fix to the route, update the nav card,
  /// push to the clock and keep the camera on the car.
  void _handleNav(LatLng pos, {required double speedMps}) {
    // Off-route re-route uses the RAW fix — a snapped point is always on the
    // route, so it could never trigger. The latch only clears once the car is
    // clearly back on the road (<30 m): GPS noise near the 50 m edge can no
    // longer reset the 5 s timer, so a real deviation still reroutes.
    // Stationary (<~5 km/h) never reroutes — a bad fix at a red light
    // shouldn't yank the route.
    final off = _engine!.offRouteDistance(pos);
    final spd = speedMps.isNaN ? 0.0 : speedMps;

    // Detect if driver is moving in a new direction divergent from route (>65°).
    final travelHeading = _heading;
    final routeBearing = _engine!.routeBearing();
    final headingDiff = travelHeading != null
        ? ((travelHeading - routeBearing + 540) % 360 - 180).abs()
        : 0.0;
    final isNewDirection = headingDiff > 65.0 && spd >= 1.8;

    // NETWORK matching override: while a fresh network snap says the nearest
    // road IS on the route (the fix just reads off line — parallel street,
    // lane offset, GPS wander), trust it over the raw distance and skip the
    // reroute. The verdict expires in 2 s so a real deviation (snap will flip
    // it off within ~1 s) always reroutes.
    // However, if the vehicle is moving in a divergent direction (turning
    // onto a cross street / ramp), do NOT let network snap suppress it.
    final netOnRoute =
        _netOnRoute &&
        !isNewDirection &&
        _lastNetMatch != null &&
        DateTime.now().difference(_lastNetMatch!) < const Duration(seconds: 2);
    if (!netOnRoute) {
      if (spd > 1.4) {
        final now = DateTime.now();
        final since = _offRouteSince ??= now;
        final elapsed = now.difference(since);

        // Immediate reroute if gone too far (>70 m).
        // Fast reroute (1.5 s) if heading in a new direction (>35 m).
        // Standard reroute (2.5 s) if off-route (>45 m).
        final isTooFar = off > 70;
        final isFastNewDir =
            isNewDirection &&
            off > 35 &&
            elapsed >= const Duration(milliseconds: 1500);
        final isOffRoute =
            off > 45 && elapsed >= const Duration(milliseconds: 2500);

        if (isTooFar || isFastNewDir || isOffRoute) {
          _offRouteSince = null;
          unawaited(
            _reRoute(
              pos,
              speedMps: speedMps,
              startHeading: spd >= 1.5 ? travelHeading : null,
            ),
          );
          return;
        }
      } else if (off < 30 && !isNewDirection) {
        _offRouteSince = null;
      }
    }
    // If a reroute calculation is actively in flight, do not snap the car
    // onto the abandoned old route or advance old maneuvers.
    if (_isRerouting) {
      _current = pos;
      _logFix(pos, speedMps);
      _map.move(pos, 17);
      if (mounted) setNavState(() {});
      return;
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
    _sendToClock(nav);
    _maybeSpeakManeuver(nav);
    _maybeSpeakOverspeed(spd);
    _checkCameraAhead(snapped, _route?.geometry ?? const []);
    // Road signs: announce the next STOP / give-way sign ahead (traffic
    // lights are map-only). Offline index, ~1 Hz throttle inside.
    _checkSignAhead(snapped, _route?.geometry ?? const []);
    // Keep the nav-map camera/sign layer near the car (~1 s, same cadence as
    // the GPS fix) so it stays a handful of markers instead of a whole route's
    // worth, AND updates as the car moves past a sign/camera (the old 5 s lag
    // made markers pop in late; the user: "run update near by on route nearby
    // camera + sign", then "2s still too long, can we update 1s"). The isolate
    // query + 30-item cap keep it cheap on the low-end phone.
    final nlNow = DateTime.now();
    if (_lastNearbyLayers == null ||
        nlNow.difference(_lastNearbyLayers!) >= const Duration(seconds: 1)) {
      _lastNearbyLayers = nlNow;
      unawaited(_refreshRouteCameras());
    }
    _refreshRoad(snapped);
    // Waze parity: the posted limit AND the street name come from the layer
    // under the car, so refresh them on EVERY fix — at the RAW position, with
    // the route-snapped point only as a fallback (see _correctSpeedFromWaze).
    // This used to ride inside _refreshRoad's throttle (600 ms + 15 m, 2 s
    // idle), which is why turning onto a new street left the old limit on
    // screen, and why the snapped point silently missed the segment that
    // exists under the car.
    unawaited(_correctSpeedFromWaze(pos, snapped: snapped));
    // Speak when the posted limit changes (crossing onto another road / a new
    // posted sign).
    _maybeSpeakLimitChange();
    _logFix(pos, speedMps);
    // Background nav: live notification + heads-up at each new maneuver.
    unawaited(
      NavForegroundService.instance.updateNav(nav, eta: _etaLabel(nav)),
    );
    unawaited(NavForegroundService.instance.notifyManeuver(nav));
    _map.move(snapped, 17);
    // ESP display: refresh the near path-ahead as the car advances (the board
    // only shows ~1.5 km at zoom 15, so we keep the drawn lane just ahead of
    // the car instead of one static whole-route frame).
    final now = DateTime.now();
    if (_mapClock.isConnected &&
        (_lastMapRouteSend == null ||
            now.difference(_lastMapRouteSend!) >= const Duration(seconds: 4))) {
      _lastMapRouteSend = now;
      unawaited(_sendMapRoute());
    }
    if (mounted) setNavState(() {});
  }

  /// "ETA 14:32" label for the background notification.
  String _etaLabel(NavProgress nav) {
    final h = nav.etaHour < 10 ? '0${nav.etaHour}' : '${nav.etaHour}';
    final m = nav.etaMinute < 10 ? '0${nav.etaMinute}' : '${nav.etaMinute}';
    return 'ETA $h:$m';
  }

  /// Re-navigation: fetch a fresh route from [from] to the destination.
  /// Keeps the current navigation running and snaps straight into the new
  /// route so the UI + clock update immediately.
  Future<void> _reRoute(
    LatLng from, {
    double speedMps = 0,
    double? startHeading,
  }) async {
    if (_isRerouting) return;
    // Cooldown: don't re-route-spam while GPS is jittery off-route.
    final now = DateTime.now();
    if (_lastReRoute != null &&
        now.difference(_lastReRoute!) < const Duration(seconds: 4)) {
      return;
    }
    _isRerouting = true;
    _lastReRoute = now;
    _offRouteSince = null;
    _netOffSince = null;
    if (mounted) setNavState(() {});

    debugPrint('SIM: REROUTE from=$from heading=$startHeading');
    final dest = _destination;
    if (dest == null) {
      _isRerouting = false;
      if (mounted) setNavState(() {});
      return;
    }

    // Throttle reroute speech to at most once every 12 seconds to prevent audio nag.
    if (_lastRerouteSpeech == null ||
        now.difference(_lastRerouteSpeech!) >= const Duration(seconds: 12)) {
      _lastRerouteSpeech = now;
      _voice.speak(
        'Đang tính lại lộ trình.',
        priority: VoiceGuide.priorityHigh,
      );
    }
    final sw = Stopwatch()..start();
    try {
      final currentStopIdx = _engine?.currentStopIndex ?? 0;
      final remainingStops = _stops.length > currentStopIdx
          ? _stops.sublist(currentStopIdx)
          : <TripStop>[];
      final points = <LatLng>[
        from,
        if (remainingStops.isNotEmpty)
          ...remainingStops.map((s) => s.pos)
        else
          dest,
      ];
      final effHeading = startHeading ?? (speedMps >= 1.5 ? _heading : null);
      // Fast-fail the ONLINE attempts (Google/Vietmap can block 30–60 s in a
      // dead zone) — cap them at 5 s and fall back to the on-device graph /
      // OSRM so turn-by-turn guidance keeps updating in a tunnel or rural gap.
      final route = await fetchAnyRoute(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
        preference: _routePreference,
        onlineTimeout: const Duration(seconds: 5),
        startHeading: effHeading,
      );
      sw.stop();
      debugPrint(
        'REROUTE: fetched ${route.distance.toStringAsFixed(0)}m in '
        '${sw.elapsedMilliseconds}ms '
        '(graph=${OfflineRouter.instance.isLoaded} '
        'engine=$routingEngine)',
      );
      if (!mounted || _destination == null) return;
      // Start the DRAWN route from the car's REAL fix: OSRM snaps the first
      // coordinate to the road, so a fresh reroute would begin at the street
      // instead of the car. Bridge the small gap with interpolated points so
      // the polyline starts where the car actually is.
      final bridged = _bridgeRouteFrom(route, from);
      setNavState(() {
        _route = bridged;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _showSteps = false;
        _routeBearing = 0;
        _routeStartIndex = 0;
        if (remainingStops.isNotEmpty) {
          _stops
            ..clear()
            ..addAll(remainingStops);
        }
        _engine = TurnByTurnEngine(
          bridged,
          stopNames: _engineStopNames(bridged),
          maxSpeedMps: _routeProfile.legalMaxMps,
        );
        _lastManeuverSig = null;
        _spokenFar = false;
        _spokenNear = false;
        _spokenFinal = false;
        _arrivedSpoken = false;
      });
      // Snap straight into the new route using the latest position.
      _isRerouting = false;
      final latestPos = _lastFixPos ?? _current ?? from;
      _handleNav(latestPos, speedMps: speedMps);
      _sendMapRoute();

      // If the newly calculated route starts with a turnaround / U-turn (e.g. dead end forward),
      // tell the driver: "Không có đường đi tiếp, vui lòng quay đầu xe."
      final firstStep = route.steps.isNotEmpty ? route.steps.first : null;
      final isTurnBack =
          firstStep != null &&
          (firstStep.modifier?.contains('uturn') == true ||
              firstStep.type == 'uturn');
      if (isTurnBack) {
        _voice.speak(
          'Không có đường đi tiếp, vui lòng quay đầu xe.',
          priority: VoiceGuide.priorityCritical,
        );
      }
    } catch (e) {
      // keep the old route on failure — but TELL the driver so they know the
      // reroute didn't take and they must turn back.
      debugPrint('REROUTE: failed: $e — keeping the old route');
      _voice.speak(
        'Không tìm thấy đường đi tiếp, vui lòng quay lại.',
        priority: VoiceGuide.priorityHigh,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Không tìm thấy đường đi tiếp — vui lòng quay lại.',
              ),
              duration: Duration(seconds: 3),
            ),
          );
      }
    } finally {
      _isRerouting = false;
      if (mounted) setNavState(() {});
    }
  }

  /// Rebuild [route] with the real [from] fix prepended (plus a few
  /// interpolated points toward OSRM's snapped start) so the drawn polyline
  /// begins at the car, not at the road. Also offsets the first step distance
  /// and stopCumulative by [gap] so maneuver countdowns remain in exact sync.
  OsrmRoute _bridgeRouteFrom(OsrmRoute route, LatLng from) {
    final g = route.geometry;
    if (g.isEmpty) return route;
    final first = g.first;
    final gap = distanceMeters(from, first);
    if (gap < 2) return route;
    final pts = <LatLng>[from];
    const n = 3;
    for (var i = 1; i <= n; i++) {
      final t = i / (n + 1);
      pts.add(
        LatLng(
          from.latitude + (first.latitude - from.latitude) * t,
          from.longitude + (first.longitude - from.longitude) * t,
        ),
      );
    }
    pts.addAll(g);
    final adjustedSteps = route.steps.isEmpty
        ? route.steps
        : [
            OsrmStep(
              name: route.steps.first.name,
              distance: route.steps.first.distance + gap,
              duration: route.steps.first.duration,
              type: route.steps.first.type,
              modifier: route.steps.first.modifier,
              maneuver: route.steps.first.maneuver,
              congestion: route.steps.first.congestion,
            ),
            ...route.steps.skip(1),
          ];
    final adjustedStopCum = [for (final s in route.stopCumulative) s + gap];
    return OsrmRoute(
      distance: route.distance + gap,
      duration: route.duration,
      geometry: pts,
      steps: adjustedSteps,
      stopCumulative: adjustedStopCum,
      tollCost: route.tollCost,
      tolls: route.tolls,
    );
  }

  Future<void> _sendToClock(NavProgress nav) async {
    // ESP32 2.8" map display overlay feed (no-op when not connected).
    await _sendToMap(nav);
  }

  /// Push the overlay frames to the ESP32 2.8" display (NAV-OSM board):
  /// live position, next maneuver, ETA and the current HUD time. Each packet
  /// replaces the previous one on the board, so a dropped write self-heals
  /// on the next ~1 Hz tick.
  Future<void> _sendToMap(NavProgress nav) async {
    if (!_mapClock.isConnected) return;
    final cur = _current;
    if (cur != null) {
      await _mapClock.sendFrame(
        buildMapPosFrame(
          lat: cur.latitude,
          lon: cur.longitude,
          spd: (_lastSpeedMps * 3.6).round().clamp(0, 255),
          hdg: _routeBearing.round() % 360,
          speedLimit: _effectiveSpeedLimit,
        ),
      );
    }
    await _mapClock.sendFrame(
      buildMapNavFrame(
        dist: nav.meter,
        maneuverId: mapManeuverIdForIcon(nav.iconCode),
        street: nav.text,
      ),
    );
    // Second maneuver (0x08) — the turn AFTER the upcoming one, shown as the
    // board's secondary HUD maneuver. Only sent when there is one.
    if (nav.nextIconCode != 0 || nav.nextNextText.isNotEmpty) {
      await _mapClock.sendFrame(
        buildMapNav2Frame(
          dist: nav.nextMeter,
          maneuverId: mapManeuverIdForIcon(nav.nextIconCode),
          street: nav.nextNextText,
        ),
      );
    }
    // Speed camera ahead (0x09) — dist=0 clears the alert when none is near.
    await _mapClock.sendFrame(
      buildMapCameraFrame(
        dist: _nextCamera?.routeMeters.round().clamp(0, 0xFFFF) ?? 0,
        // All bundled cameras are static; type 1 = mobile ("MOBILE CAM").
        type: 0,
      ),
    );
    await _mapClock.sendFrame(
      buildMapEtaFrame(
        hour: nav.etaHour,
        minute: nav.etaMinute,
        arrive: _destinationName,
      ),
    );
    // HUD clock — only when the minute ticks.
    final now = DateTime.now();
    if (now.minute != _lastMapClockMinute) {
      _lastMapClockMinute = now.minute;
      await _mapClock.sendFrame(
        buildMapClockFrame(hour: now.hour, minute: now.minute),
      );
    }
  }

  /// Send the path-ahead polyline to the ESP32 display (once per route /
  /// re-route). The board draws it as a thick blue line over its local tiles
  /// — but it only shows ~1.5 km of map at zoom 15, so sending the whole
  /// (multi-km) route made the decimated points span the entire screen
  /// instead of tracing the visible streets.
  ///
  /// So we send only the [kMapAheadMeters]-long window in front of the car
  /// (starting at the current snapped index), resampled to the ESP's
  /// `MAX_ROUTE_DRAW_PTS` (24) points. Re-sent on a timer while navigating
  /// (see `_handleNav`) so the lane stays just ahead of the car.
  static const double kMapAheadMeters = 2000;
  Future<void> _sendMapRoute() async {
    if (!_mapClock.isConnected) return;
    final engine = _engine;
    if (engine == null) return;
    final geometry = engine.route.geometry;
    if (geometry.isEmpty) return;
    // Window starts at the car's snapped position (or route start pre-nav).
    final start = _routeStartIndex.clamp(0, geometry.length - 1);
    final ahead = <LatLng>[geometry[start]];
    var d = 0.0;
    for (var i = start + 1; i < geometry.length; i++) {
      ahead.add(geometry[i]);
      d += distanceMeters(geometry[i - 1], geometry[i]);
      if (d >= kMapAheadMeters) break;
    }
    await _mapClock.sendFrame(
      buildMapRouteFrame(_decimateRoute(ahead, max: 24)),
    );
    // Route continuation: the rest of the route beyond the near window, drawn
    // faint behind it so the driver sees where the road goes next. Resampled to
    // the ESP's parse cap (64) so it's never dropped.
    if (start + 1 < geometry.length) {
      final cont = <LatLng>[geometry[start + 1], ...geometry.skip(start + 1)];
      if (cont.length > 1) {
        await _mapClock.sendFrame(
          buildMapRouteContFrame(_decimateRoute(cont, max: 64)),
        );
      }
    }
  }

  /// Send the current weather to the ESP banner (type 0x07). Best-effort.
  Future<void> _sendMapWeather() async {
    if (!_mapClock.isConnected) return;
    final w = _weather;
    if (w == null || w.tempC == null) return;
    final frame = buildMapWeatherFrame(
      tempC: w.tempC!.round(),
      humidity: (w.humidityPct ?? 0).round(),
      code: w.weatherCode ?? 0,
      text: weatherTextForCode(w.weatherCode),
    );
    // Prefer the dedicated weather service; fall back to the nav char (both
    // route the frame through the same parser on the board).
    final ok = await _mapClock.sendWeatherFrame(frame);
    if (!ok) await _mapClock.sendFrame(frame);
  }

  /// Resample a route polyline to at most [max] points, evenly spaced, keeping
  /// both the first and last points (the path must still reach the destination).
  /// Defaults to the ESP's `NAV_MAX_ROUTE_POINTS` (64).
  List<LatLng> _decimateRoute(List<LatLng> geometry, {int max = 64}) {
    if (geometry.length <= max) return geometry;
    final pts = <LatLng>[];
    final stride = (geometry.length - 1) / (max - 1);
    for (var i = 0; i < max; i++) {
      pts.add(geometry[(i * stride).round().clamp(0, geometry.length - 1)]);
    }
    return pts;
  }

  Future<void> _startNavigation() async {
    // Re-entry latch: tapping "Bắt đầu chỉ đường" twice (slow phone, double
    // tap, or a voice command racing the button) used to start navigation
    // twice and double the side effects (trip log, BLE frames, PiP).
    // _navigating only flips AFTER the async start sequence, so guard here.
    if (_navStarting || _navigating) return;
    _navStarting = true;
    debugPrint('SIM: START navigation pressed');
    final engine = _engine;
    if (engine == null) {
      _navStarting = false;
      return;
    }
    final origin = await _resolveOrigin();
    if (origin == null) {
      _navStarting = false;
      return;
    }
    // The engine snaps the car to the NEAREST route point — so if the user
    // starts navigation while NOT at the route's start (e.g. GPS at home but
    // the route was planned from elsewhere), it can snap near the DESTINATION
    // and immediately say "bạn đã đến nơi". Guard: if the car is far from the
    // route start, ask whether to re-route from the current position instead.
    final routeStart = engine.route.geometry.isEmpty
        ? origin
        : engine.route.geometry.first;
    final startGap = distanceMeters(origin, routeStart);
    if (startGap > 80) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Chưa ở điểm bắt đầu'),
          content: Text(
            'Vị trí hiện tại cách điểm bắt đầu ${startGap.round()} m.\n'
            'Bắt đầu chỉ đường từ vị trí hiện tại?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Huỷ'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Chỉ đường từ đây'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) {
        _navStarting = false;
        return;
      }
      // Re-route from the car's real position so the polyline/engine start
      // where the user actually is (no more "arrived" at the wrong spot).
      final rerouted = await _rerouteFromCurrent(fallback: origin);
      if (rerouted == null) {
        _navStarting = false;
        return;
      }
      final e2 = _engine;
      if (e2 == null) {
        _navStarting = false;
        return;
      }
      _navStarting = false; // nav actually started — reopen the latch
      navigationActive = true;
      setNavState(() => _navigating = true);
      _beginTrip();
      final nav = e2.update(origin, speedMps: 0);
      _progress = nav;
      _logFix(origin, 0);
      _sendToClock(nav);
      _sendMapRoute();
      _spokenFar = false;
      _spokenNear = false;
      _spokenFinal = false;
      _arrivedSpoken = false;
      _lastManeuverSig = null;
      _speedingSpoken = false;
      _lastOverspeedAt = null;
      _resetSignSpeed(); // speed-limit sign + announce reset per session
      _gpsWeakSpoken = false;
      _lastGpsWeakAt = null;
      _offRouteSince = null;
      _routeStartIndex = 0;
      _gpsWindow.clear();
      _startWeather();
      _startFuelWatch();
      if (radarOn) unawaited(_ensureRadar());
      unawaited(WakelockPlus.enable());
      unawaited(NavForegroundService.instance.start());
      unawaited(PipService.instance.setAspect(pipAspect));
      unawaited(PipService.instance.setAutoEnter(true));
      if (mounted) setNavState(() {});
      return;
    }
    _navStarting = false; // nav actually started — reopen the latch
    navigationActive = true;
    setNavState(() => _navigating = true);
    _beginTrip(); // auto-record the real drive
    final nav = engine.update(origin, speedMps: 0);
    _progress = nav;
    _logFix(origin, 0);
    _sendToClock(nav);
    _sendMapRoute();
    _spokenFar = false;
    _spokenNear = false;
    _spokenFinal = false;
    _arrivedSpoken = false;
    _lastManeuverSig = null;
    _speedingSpoken = false;
    _lastOverspeedAt = null;
    _resetSignSpeed(); // speed-limit sign + announce reset per session
    _gpsWeakSpoken = false;
    _lastGpsWeakAt = null;
    _offRouteSince = null;
    _routeStartIndex = 0; // full route at the start of navigation
    _gpsWindow.clear();
    _startWeather();
    _startFuelWatch();
    if (radarOn) unawaited(_ensureRadar());
    unawaited(_refreshRouteCameras()); // nav-map camera layer for the route
    unawaited(WakelockPlus.enable()); // keep the screen on while navigating
    unawaited(
      NavForegroundService.instance.start(),
    ); // background nav + notification
    // PiP (Part C): pressing Home during nav auto-enters the small window.
    // Sync the configured window shape first so auto-enter uses it too.
    unawaited(PipService.instance.setAspect(pipAspect));
    unawaited(PipService.instance.setAutoEnter(true));
    if (mounted) setNavState(() {});
  }

  /// Simulated drive (testing without GPS): walk the car along the route at
  /// ~58 km/h via [TurnByTurnEngine.positionAtDistance], feeding the same
  /// `_handleNav` pipeline as real GPS so maneuvers / voice / camera checks
  /// all fire. Real fixes are ignored while [_simulating].
  Future<void> _startSimulation() async {
    if (_navigating || _simulating) return; // never start the sim twice
    final engine = _engine;
    if (engine == null || _route == null) return;
    _simTimer?.cancel();
    _simDist = 0; // walk the route from its start
    navigationActive = true;
    setNavState(() {
      _navigating = true;
      _simulating = true;
    });
    _beginTrip();
    _spokenFar = false;
    _spokenNear = false;
    _spokenFinal = false;
    _arrivedSpoken = false;
    _lastManeuverSig = null;
    _speedingSpoken = false;
    _lastOverspeedAt = null;
    _resetSignSpeed(); // speed-limit sign + announce reset per session
    _gpsWeakSpoken = false;
    _lastGpsWeakAt = null;
    _cameraDedupe.reset();
    _cameraGate.reset(); // camera checks run fresh during the sim
    _offRouteSince = null;
    _gpsWindow.clear();
    _startWeather();
    _startFuelWatch();
    unawaited(_refreshRouteCameras()); // nav-map camera layer for the route
    unawaited(WakelockPlus.enable());
    unawaited(NavForegroundService.instance.start());
    unawaited(PipService.instance.setAspect(pipAspect));
    debugPrint(
      'SIM: simulation START (route ${engine.route.distance.round()}m)',
    );
    // Kalman noise demo: run a synthetic noisy GPS trace (movement + position
    // noise + speed noise) through a dedicated LocationKalman and log how much
    // the filter cuts the jitter. Proves the smoothing on-device — logcat
    // shows "KALMAN: ..." every few seconds while the sim runs.
    final noiseSim = GpsNoiseSimulator(
      speedMps: 16,
      positionSigma: 5,
      speedSigma: 1.5,
      fixIntervalMs: 500, // matches the 500 ms sim ticker (~58 km/h)
      seed: 7,
    );
    final noiseKf = LocationKalman();
    var noiseN = 0;
    var noiseRaw = 0.0, noiseFilt = 0.0;
    var lastNoiseLog = DateTime.now().millisecondsSinceEpoch;
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final e = _engine;
      if (e == null) return;
      _simDist += 8; // ~58 km/h
      if (_simDist >= e.route.distance) {
        _simDist = e.route.distance;
        _stopSimulation();
      }
      final pos = e.positionAtDistance(_simDist);
      _handleNav(pos, speedMps: 16);
      // Kalman noise demo (logged to logcat every ~4 s).
      final sf = noiseSim.next();
      noiseKf.update(
        sf.measured,
        accuracy: sf.accuracy,
        speedMps: sf.speedMps,
        speedNoise: sf.speedNoise,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      noiseRaw += GpsNoiseSimulator.metersBetween(sf.truth, sf.measured);
      noiseFilt += GpsNoiseSimulator.metersBetween(sf.truth, noiseKf.position!);
      noiseN++;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastNoiseLog >= 4000) {
        lastNoiseLog = nowMs;
        final cut = 100 * (1 - noiseFilt / noiseRaw);
        debugPrint(
          'KALMAN: sim noise raw=${(noiseRaw / noiseN).toStringAsFixed(1)}m '
          'filt=${(noiseFilt / noiseN).toStringAsFixed(1)}m '
          'smooth=${cut.toStringAsFixed(0)}% '
          'speed=${noiseKf.speedMps.toStringAsFixed(1)}m/s '
          '(true=${sf.trueSpeed.toStringAsFixed(1)})',
        );
      }
      setNavState(() {});
    });
    if (mounted) setNavState(() {});
  }

  /// Stop the simulated drive (real navigation keeps running).
  void _stopSimulation() {
    _simTimer?.cancel();
    _simTimer = null;
    if (!_simulating) return;
    setNavState(() => _simulating = false);
    debugPrint('SIM: simulation stopped');
  }

  /// Re-route from the car's current position to the planned destination and
  /// swap the engine over. Returns the new engine (or null on failure).
  /// [fallback] is the already-resolved origin — used when there is no live
  /// fix yet (last known / default city).
  Future<TurnByTurnEngine?> _rerouteFromCurrent({LatLng? fallback}) async {
    final cur = _current ?? fallback;
    final dest = _destination;
    if (cur == null || dest == null) return null;
    final points = <LatLng>[
      cur,
      if (_stops.isNotEmpty) ..._stops.map((s) => s.pos) else dest,
    ];
    try {
      final route = await fetchAnyRoute(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
        preference: _routePreference,
      );
      if (!mounted || _destination == null) return null;
      final bridged = _bridgeRouteFrom(route, cur);
      final engine = TurnByTurnEngine(
        bridged,
        stopNames: _engineStopNames(bridged),
        maxSpeedMps: _routeProfile.legalMaxMps,
      );
      setNavState(() {
        _route = bridged;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _showSteps = false;
        _routeBearing = 0;
        _routeStartIndex = 0;
        _engine = engine;
        _lastManeuverSig = null;
        _spokenFar = false;
        _spokenNear = false;
        _spokenFinal = false;
        _arrivedSpoken = false;
      });
      unawaited(_refreshRouteCameras());
      return engine;
    } catch (_) {
      return null;
    }
  }

  /// Manual PiP entry (the nav-controls PiP button). No-op / toast on devices
  /// that don't support it.
  Future<void> _enterPip() async {
    final ok = await PipService.instance.enter(aspect: pipAspect);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thiết bị không hỗ trợ cửa sổ nổi')),
      );
    }
  }

  Future<void> _exitNavigation() async {
    debugPrint('SIM: EXIT navigation called');
    _stopSimulation(); // cancel the simulated-drive timer if running
    navigationActive = false;
    setNavState(() {
      _navigating = false;
      _simulating = false;
      _isRerouting = false;
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
      _elevation = null;
      _pois = [];
      _poiType = null;
      _selectedPoi = null;
      _searchResults = [];
      _routeSigns = [];
      _signDedupe.reset();
    });
    unawaited(_refreshRouteCameras()); // route cleared → layer empties
    _offRouteSince = null;
    _gpsWindow.clear();
    _stopWeather();
    _stopFuelWatch();
    _weatherAhead = null; // PiP weather-ahead is nav-only
    unawaited(WakelockPlus.disable()); // screen can sleep again
    unawaited(NavForegroundService.instance.stop()); // stop background nav
    // PiP (Part C): no auto-PiP while browsing, and leave the small window if
    // nav ends while it's open.
    unawaited(PipService.instance.setAutoEnter(false));
    PipService.instance.isPipMode.value = false;
    if (mounted) setNavState(() => _pipActive = false);
    await _finishTrip(); // save the recorded trip
  }

  /// Single button for the ESP32 2.8" nav display (NAV-OSM).
  /// If connected, tapping disconnects; otherwise it opens the picker.
  Future<void> _toggleDisplays() async {
    if (_mapClock.isConnected) {
      _autoConnect.notifyUserDisconnected();
      await _mapClock.disconnect();
      if (mounted) {
        setNavState(() {
          _mapStatus = 'off';
        });
      }
      return;
    }
    _autoConnect.rearm();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) =>
          DevicePickerSheet(mapClock: _mapClock, onPicked: _connectTo),
    );
  }

  /// Connect to the picked ESP32 nav display (NAV-OSM / NAVMAP).
  Future<void> _connectTo(ScannedClockDevice device) async {
    if (!mounted) return;
    _autoConnect.rearm();
    setNavState(() {
      _mapStatus = 'connecting';
    });
    try {
      await _mapClock.connect(mac: device.id);
      if (mounted) setNavState(() => _mapStatus = 'connected');
      // Push the current route + progress so the display shows nav right
      // away instead of waiting for the next GPS tick.
      _sendMapRoute();
      final nav = _progress;
      if (nav != null) _sendToMap(nav);
      lastBleMac = device.id;
      lastBleName = device.name;
      lastBleType = 'map';
      final s = await loadSettings();
      await saveSettings(
        s.copyWith(
          lastBleMac: device.id,
          lastBleName: device.name,
          lastBleType: 'map',
        ),
      );
    } catch (e) {
      if (mounted) {
        setNavState(() {
          _mapStatus = 'off';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('BLE: $e')));
      }
    }
  }
}
