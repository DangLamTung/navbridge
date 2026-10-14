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
      // Don't subscribe: the stream would error immediately and _restartGps
      // would hot-loop subscribe→error→restart every 2 s. The lifecycle
      // observer restarts GPS when the user returns (granted or not).
      return false;
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
    if (TripReplay.armed) {
      unawaited(_startReplayGps());
      return;
    }
    // A track SIMULATION owns the fix stream: opening the real receiver on top
    // of it would put two sources on `_onGpsFix` — the double-feed that made a
    // replay's marker jump (2026-10-08). See nav_track_sim.dart.
    if (_trackSimRunning) return;
    // Seed the position quickly: a one-shot network-assisted fix (fast, via
    // the fused provider) so the map centers on the user right away instead
    // of waiting for the stream's first satellite fix — which is slow on the
    // itel and is what made the GPS feel laggy at launch. The 1 Hz stream
    // then takes over.
    unawaited(_seedGpsFix());
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 1000),
      ),
    ).listen(
      _onGpsFix,
      onError: (Object e) {
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

  /// [preloaded] is the list the console just parsed for this run. Re-loading
  /// here would download and parse the trip a second time — for a long drive
  /// (18 MB, 84k fixes) that doubled both the peak memory and the start-up
  /// pause, and in the browser it wedged the page before the first fix.
  Future<void> _startReplayGps([List<ReplayFix>? preloaded]) async {
    final fixes = preloaded ?? await TripReplay.load();
    if (!mounted) return;
    if (fixes.isEmpty) {
      debugPrint(
        'REPLAY: "${TripReplay.source}" produced no fixes — no GPS source.',
      );
      simEndRun(SimRunState.failed);
      return;
    }
    final km = replayTripMeters(fixes) / 1000.0;
    final span = replayTripDuration(fixes);
    final x = TripReplay.speed;
    final from = TripReplay.startFrom.clamp(0, fixes.length - 1);
    debugPrint(
      'REPLAY: ${fixes.length} fixes, ${km.toStringAsFixed(2)} km, '
      '${span.inMinutes}m${span.inSeconds % 60}s of drive time, '
      '${x == 0 ? 'as fast as the pipeline takes them' : '$x×'}'
      '${from > 0 ? ', starting at fix $from' : ''}',
    );
    setNavClock(() => _lastGpsFixTime ?? fixes[from].at);
    _startedReplay = true;
    TripReplay.running = true;
    _replayRoadKey = ''; // a new run must publish its first recorded road
    _layerHold.forget(); // and must not inherit the last run's held limit
    if (from > 0) _current = fixes[from].point;
    // ⭐ Cancel whatever this page was already listening to, BEFORE replacing
    // the handle. `_startGps()` cancels its own subscription, but the replay
    // branch enters here from several places and this method awaits the trip
    // load first, so two overlapping calls both got past that cancel and the
    // second one just overwrote `_gpsSub` — leaving the first stream alive and
    // feeding `_onGpsFix` forever (the double-feed behind `fix 1062/540` and
    // the jumping marker, 2026-10-08).
    await _gpsSub?.cancel();
    _gpsSub = null;
    _gpsSub = replayPositionStream(fixes, speed: x, from: from).listen(
      _onGpsFix,
      onError: (Object e) => debugPrint('REPLAY: stream error: $e'),
      onDone: () {
        _startedReplay = false;
        TripReplay.running = false;
        resetNavClock();
        _reportReplayOutcome(SimRunState.done);
        if (mounted) setNavState(() {});
      },
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

  /// True while the ESP32 GPS bridge has a fresh, valid fix (last frame or
  /// NMEA line parsed < 4 s ago). While true the receiver wins — the phone's
  /// GPS is ignored (ESP-first, phone fallback).
  bool _espActive() {
    final at = _espFixAt;
    if (!_espValid || at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 4);
  }

  /// One raw NMEA line from the ESP32 display's GPS broadcast. Parses it into
  /// a fix and, when valid, feeds it through the same pipeline as a phone fix
  /// (outlier gate + heading filter + map + speed chip + trip log).
  void _onEspNmea(String line) {
    final fix = _nmea.push(line);
    debugPrint('GPS/ESP: nmea="$line"');
    if (fix == null) return;
    _espValid = fix.valid;
    _espFixAt = DateTime.now();
    if (!fix.valid) return;
    // The board streams ~one NMEA line/sec; GGA and RMC both carry position,
    // so throttle feeding to ~2 Hz to avoid double-processing the same fix.
    final now = DateTime.now();
    if (_espLastFeed != null &&
        now.difference(_espLastFeed!) < const Duration(milliseconds: 400)) {
      return;
    }
    _espLastFeed = now;
    final pos = Position(
      latitude: fix.lat,
      longitude: fix.lon,
      // All timestamps are UTC so the outlier gate's dt stays consistent with
      // the geolocator's (also UTC) fixes when the source switches.
      timestamp: fix.timeUtc ?? DateTime.now().toUtc(),
      accuracy: fix.accuracyMeters,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: fix.heading,
      speed: fix.speedMps,
      speedAccuracy: 0,
      headingAccuracy: 0,
    );
    _onGpsFix(pos, fromEsp: true);
  }

  /// One compact AA55 GPS frame (type 0x0A) from the ESP bridge — the board's
  /// current protocol. Feeds the fix through the same pipeline (ESP-first).
  void _onEspGpsFrame(Uint8List bytes) {
    final f = parseMapGpsFrame(bytes);
    if (f == null) return;
    _espValid = f.valid;
    _espFixAt = DateTime.now();
    if (!f.valid) return;
    final now = DateTime.now();
    // The compact frame has no speed/heading — derive them from the movement
    // between consecutive 1 Hz frames.
    final cur = LatLng(f.lat, f.lon);
    if (_espPrevPos != null && _espPrevAt != null) {
      final dt = now.difference(_espPrevAt!).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        final dist = fastDistanceMeters(_espPrevPos!, cur);
        _espSpeedMps = dist / dt;
        if (dist > 1.0) {
          _espHeading = _bearingDeg(_espPrevPos!, cur);
        }
      }
    }
    _espPrevPos = cur;
    _espPrevAt = now;
    // Throttle to ~2 Hz (frames arrive at 1 Hz; symmetric with the NMEA path).
    if (_espLastFeed != null &&
        now.difference(_espLastFeed!) < const Duration(milliseconds: 400)) {
      return;
    }
    _espLastFeed = now;
    debugPrint(
      'GPS/ESP: frame q=${f.quality} sats=${f.sats} '
      '${f.lat.toStringAsFixed(6)},${f.lon.toStringAsFixed(6)} '
      '${(_espSpeedMps ?? 0) * 3.6}km/h',
    );
    final pos = Position(
      latitude: f.lat,
      longitude: f.lon,
      timestamp: now.toUtc(),
      accuracy: f.accuracyMeters,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: _espHeading ?? 0,
      speed: _espSpeedMps ?? 0,
      speedAccuracy: 0,
      headingAccuracy: 0,
    );
    _onGpsFix(pos, fromEsp: true);
  }

  /// True course (deg 0..359, N=0) from [a] to [b].
  double _bearingDeg(LatLng a, LatLng b) {
    const kPi = 3.141592653589793;
    final lat1 = a.latitude * kPi / 180;
    final lat2 = b.latitude * kPi / 180;
    final dLon = (b.longitude - a.longitude) * kPi / 180;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / kPi + 360) % 360;
  }

  /// Shared GPS-fix handler (stream fixes + the fast seed + ESP NMEA). Updates
  /// the map, the engine and (in nav mode) the ETA/voice/clock.
  ///
  /// [fromSim] marks the SIMULATED drive's own synthesised feed. Without it the
  /// guard below swallowed the whole simulation: the sim owns the route, so real
  /// fixes are dropped while it runs — including the fixes the sim itself was
  /// pushing through here, which is why a simulation produced a trip with ZERO
  /// fixes (2026-10-08). The guard's purpose is unchanged: the phone's stationary
  /// GPS must not yank the car back off the simulated route.
  void _onGpsFix(Position p, {bool fromEsp = false, bool fromSim = false}) {
    // Simulated drive drives the route itself — ignore real (stationary) GPS
    // so it can't yank the car back to the phone's location (T9).
    if (_simulating && !fromSim) return;
    // ESP-first: while the receiver has a fresh valid fix, ignore the phone's
    // GPS (its antenna is worse). The phone resumes when the ESP fix goes stale.
    if (!fromEsp && _espActive()) return;
    final pos = LatLng(p.latitude, p.longitude);
    // Use the FIX's own timestamp for the outlier gate, NOT wall-clock: the
    // geolocator batch-delivers fixes, so a 10 m jump that is 0.1 s apart in
    // fix-time can look like a normal 1 s gap in wall-time — wall-clock dt let
    // the 270–449 km/h bursts through (the trip logs proved it). With fix-time
    // dt the gate sees the true short interval and rejects the burst.
    final fixTime = p.timestamp;
    final dt = _lastGpsFixTime == null
        ? null
        : fixTime.difference(_lastGpsFixTime!).inMilliseconds / 1000.0;
    // Outlier gate (Google/Mapbox-style innovation gate): reject a fix that is
    // too inaccurate or a position jump inconsistent with the recent smoothed
    // speed BEFORE it reaches the map, the complementary filter and the speed
    // chip — a single GPS burst (e.g. a 130 km/h reading) must never move the
    // arrow or flash the speed. Skipped when the user turns the GPS filter
    // off in Settings (raw mode — no fixes dropped).
    //
    // NOTE the gate can only DROP a fix, never move one: it decides between
    // "use this position" and "keep the previous one". So a run that looks
    // like it is on the wrong road cannot be caused by the filter — either the
    // raw position was already there, or the road lookup chose wrongly.
    final accepted =
        !gpsFilter ||
        _outlierGate.accept(
          pos,
          accuracy: p.accuracy,
          dt: dt,
          // The fix's own speed — only used to seed the prior when the gate is
          // cold (see OutlierGate.accept), so a drive that starts already
          // moving is not rejected forever.
          speedMps: p.speed.isFinite ? p.speed : null,
        );
    if (!accepted) {
      // A rejected fix is the ONLY case where the app deliberately ignores the
      // receiver — so it is the first thing to record when a drive's position
      // looks wrong. Previously these were dropped without a trace.
      _trip?.addRawFix(
        time: fixTime,
        lat: p.latitude,
        lng: p.longitude,
        accuracyM: p.accuracy,
        speedMps: p.speed.isFinite ? p.speed : 0,
        heading: p.heading,
        accepted: false,
        filterOn: true,
        rejectReason: _outlierGate.lastReason,
        jumpM: _outlierGate.lastJumpM,
        allowedM: _outlierGate.lastAllowedM,
        fromEsp: fromEsp,
      );
      final why = _outlierGate.lastReason == 'jump'
          ? 'jump=${_outlierGate.lastJumpM?.toStringAsFixed(0)}m>'
                '${_outlierGate.lastAllowedM?.toStringAsFixed(0)}m'
          : 'accuracy>${_outlierGate.lastAllowedM ?? ''}';
      debugPrint(
        'GPS: REJECTED $why acc=${p.accuracy}m '
        'dt=${dt == null ? '-' : dt.toStringAsFixed(2)}s '
        'at ${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}',
      );
      return;
    }
    _lastGpsFixTime = fixTime;
    // ⭐ The RAW fix, as the receiver gave it, for EVERY accepted fix too: the
    // coordinates the whole decision chain started from. Without this a
    // "the GPS was totally wrong on Trường Chinh" report could only be checked
    // against the road name the app itself published.
    _trip?.addRawFix(
      time: fixTime,
      lat: p.latitude,
      lng: p.longitude,
      accuracyM: p.accuracy,
      speedMps: p.speed.isFinite ? p.speed : 0,
      heading: p.heading,
      accepted: true,
      filterOn: gpsFilter,
      fromEsp: fromEsp,
    );
    debugPrint(
      'GPS${fromEsp ? '/ESP' : ''}: fix dt=${(dt ?? 0).toStringAsFixed(2)}s '
      'acc=${p.accuracy}m '
      'spd=${p.speed.isNaN ? 0 : p.speed.toStringAsFixed(0)} '
      'at ${p.latitude.toStringAsFixed(7)},${p.longitude.toStringAsFixed(7)}',
    );
    _current = pos;
    if (_startedReplay || _trackSimRunning) {
      simNoteFix(roadKnown: (_roadInfo?.speedLimit ?? 0) > 0);
    }
    // ⛔ The recorded road is injected ONLY for a replay. A simulation's whole
    // point is that the road has to be worked out from the map data.
    if (_startedReplay) _applyReplayRoad(fixTime);
    final spd = p.speed.isNaN ? 0.0 : p.speed;
    // Filtered heading: holds while stationary, only applies a big change
    // after two agreeing fixes (see [StrictHeading]).
    //
    // ⭐ Settings → Dẫn đường → "Nguồn hướng" picks WHERE that heading comes
    // from. 'phone' trusts the heading the receiver reports with this fix, which
    // exists even while crawling; 'travel' (default) derives it from the last
    // two fixes and holds it below the 2 m movement threshold. The heading is
    // not just cosmetic: the posted-limit segment layer picks a segment's
    // `fwd`/`rev` value from it and decides with it whether the car is RIDING
    // the segment.
    _headingFilter.update(p.heading, pos, preferPhone: _phoneHeading);
    _lastSpeedMps = spd;
    // ~1 Hz: keep the floating widget's auto-hide in sync with the map
    // (zoom-out / radar / satellite hide it). No-op unless it changed.
    _syncOverlayVisibility();
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
      // Browse: keep the near-camera layer bounded to the user (throttled to
      // a couple of km of movement) so the map never renders all ~70k markers.
      unawaited(_refreshNearCameras());
      return;
    }
    // Keep a short trace for online OSRM /match road-snapping.
    _gpsWindow.add(pos);
    if (_gpsWindow.length > 15) _gpsWindow.removeAt(0);
    _lastGpsAccuracy = p.accuracy;
    // Voice-alert when GPS accuracy degrades (fixes may wander off-road).
    _maybeSpeakGpsWeak(p.accuracy);
    unawaited(_maybeSnapToRoad());
    // Wrong-way (inverse) / new-direction re-route: driving OPPOSITE or
    // DIVERGENT from route direction while staying near the road.
    _wrongWaySince = _wrongWaySinceOf(pos, p.speed, _wrongWaySince);
    if (_wrongWaySince != null &&
        DateTime.now().difference(_wrongWaySince!) >=
            const Duration(milliseconds: 2000)) {
      _wrongWaySince = null;
      final travel = p.speed >= 1.5 ? (_heading ?? p.heading) : null;
      _reRoute(pos, speedMps: p.speed, startHeading: travel);
      return;
    }
    // Off-route detection lives in [_handleNav] (authoritative). Here we add
    // Google-style NETWORK matching (offline graph): fast road-based reroute
    // that fires when the nearest ROAD isn't part of the route — works even
    // on parallel roads where the raw >50 m distance check can't tell.
    unawaited(_networkMatch(pos));
    _handleNav(pos, speedMps: p.speed);
  }

  /// Returns when the car started driving AGAINST or DIVERGING from the route direction,
  /// or null while it's heading along the route / stationary. Latches while diverging
  /// so a single noisy fix can't reset it; resets the moment the heading realigns
  /// with the route (or the car stops).
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
    final diff = ((travel - route + 540) % 360 - 180).abs();
    // Opposite direction (>100°) or diverging into new direction (>65° at >=1.8 m/s):
    if (diff > 100 || (diff > 65 && speedMps >= 1.8)) {
      return since ?? DateTime.now();
    }
    return null;
  }

  /// Google-style NETWORK matching (offline graph): snap the fix to the
  /// nearest ROAD, then check whether that road is part of the route.
  /// - Snapped point IS on the route (<20 m) and aligned with route direction
  ///   → clear latches.
  /// - Snapped point is on a DIFFERENT road or diverging → latch and reroute
  ///   after ~2.5 s along current heading.
  /// - Fix is >25 m from ANY road (parking lot / GPS loss) → ignore.
  /// Throttled ~1/s (the native snap is cheap); only active when the offline
  /// graph is loaded, so OSRM-only routes fall back to the raw check.
  Future<void> _networkMatch(LatLng pos) async {
    if (!_navigating) return;
    final engine = _engine;
    if (engine == null || !OfflineRouter.instance.isLoaded) return;
    final now = DateTime.now();
    if (_lastNetMatch != null &&
        now.difference(_lastNetMatch!) < const Duration(seconds: 1)) {
      return;
    }
    _lastNetMatch = now;
    final snap = await OfflineRouter.instance.snapToRoad(pos);
    if (!mounted || !_navigating || snap == null) return;
    if (snap.distance > 25) return; // too far from any road — GPS loss, skip
    final snapped = LatLng(snap.lat, snap.lng);
    final onRoute = engine.offRouteDistance(snapped) < 20;

    // Check whether travel heading is diverging from the route
    final travelH = _heading;
    final routeH = engine.routeBearing();
    final hDiff = travelH != null
        ? ((travelH - routeH + 540) % 360 - 180).abs()
        : 0.0;
    final isDiverging = hDiff > 65.0 && _lastSpeedMps >= 1.8;

    _netOnRoute =
        onRoute && !isDiverging; // authoritative while fresh (see _handleNav)
    if (_netOnRoute) {
      _netOffSince = null;
      _offRouteSince = null; // network says we're on a route road — trust it
      return;
    }
    // On a road that is NOT part of the route or diverging → real deviation.
    _netOffSince ??= now;
    if (now.difference(_netOffSince!) >= const Duration(milliseconds: 2500)) {
      _netOffSince = null;
      _reRoute(
        pos,
        speedMps: _lastSpeedMps,
        startHeading: _lastSpeedMps >= 1.5 ? travelH : null,
      );
    }
  }

  /// Online GPS road-snapping: send the rolling trace to OSRM /match
  /// (throttled to 5 s) to refine the on-route position when online. The
  /// matched point is projected onto the route polyline and only accepted
  /// when it's close — between matches (and fully offline) the always-on
  /// `engine.snapToRoute` projection keeps the car on the road, so the match
  /// never causes the puck to bounce off/on the route (the old flicker).
  Future<void> _maybeSnapToRoad() async {
    if (forceOffline || _gpsWindow.length < 3 || !_navigating) return;
    // ⭐ Not during a SIMULATION, and this is a scope limit, not an optimisation
    // — the run says so in its log. `/match` is a REMOTE call on a 5 s cadence;
    // a drive fed at 8× issues one every ~0.6 s of wall clock, and the service
    // took 76 s per call when the relay first exposed it (2026-10-08), so the
    // run could never finish. It is also the one step whose result the
    // simulation cannot be missing: it only nudges the puck onto the road, and
    // simulated points are ON the route by construction ([synthesiseTrack]).
    // Everything else — outlier gate, heading filter, road lookup, limit layer,
    // signs, built-up verdict, voice, trip log — runs exactly as on a phone.
    if (_trackSimRunning) return;
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

  void _applyReplayRoad(DateTime fixTime) {
    final f = TripReplay.streetAt(fixTime);
    if (f == null) {
      // Silent before, which made "the replay never published a road"
      // indistinguishable from "the trip has no street" or "the layer missed".
      debugPrint('REPLAY: no recorded fix at $fixTime — road not published');
      return;
    }
    final street = f.street.trim();
    if (street.isEmpty) {
      // A trip whose fixes carry no `street` gets NO road on screen at all, so
      // no built-up verdict is ever evaluated and the dial stays '-'. Every
      // real recording has it (`TripLogger.addFix(streetName:)`), but a
      // hand-made fixture must set it (found 2026-10-08 on a synthetic QL20
      // trip: zero ROAD lines and no explanation).
      debugPrint('REPLAY: recorded street is EMPTY — road not published; the '
          'trip needs a `street` per fix');
      return;
    }
    final hw = f.highway.trim().isEmpty ? 'unclassified' : f.highway.trim();
    // NOTE: `_roadOsm` is NOT refreshed here any more. It is the OSM/STATUTORY
    // baseline the layer falls back to, and the road on screen may be a
    // LAYER-DERIVED value. Storing it made the fallback a no-op that returned the
    // layer's own last number — see _publishReplayRoad for the measurement.
    final key = '$street\u0000$hw\u0000${f.divided}\u0000${f.oneway}\u0000'
        '${f.lanes}';
    if (key == _replayRoadKey && _roadInfo != null) return;
    _replayRoadKey = key;
    unawaited(_publishReplayRoad(f).catchError((Object e) {
      // Nothing was published, so clear the optimistic key: leaving it set would
      // wedge this recorded road for the rest of the drive (the key is the only
      // thing _applyReplayRoad compares against).
      _replayRoadKey = '';
      debugPrint('REPLAY: road publish failed for "$street": $e');
    }));
  }

  Future<void> _publishReplayRoad(ReplayFix f) async {
    final street = f.street.trim();
    final hw = f.highway.trim().isEmpty ? 'unclassified' : f.highway.trim();
    final at = _current;
    final urban = at == null ? false : await _townAt(at);
    if (!mounted) return;
    if (TripReplay.streetAt(_lastGpsFixTime ?? DateTime.now())?.street
            .trim() != street) {
      // The fix moved on while this publish was queued, so the road was NOT
      // published — clear the key _applyReplayRoad set optimistically, or the
      // rest of the drive skips this road (the key is the whole comparison).
      _replayRoadKey = '';
      debugPrint('REPLAY: road publish skipped — the fix moved on before '
          '"$street" was published');
      return;
    }
    // ⭐ ONE constructor for both publishers ([statutoryRoad]): built inline here
    // this object silently took `RoadInfo`'s `src` default, so the replay
    // announced every in-town street as CLASS while [_correctSpeedFromWaze]
    // called the same one CITY — the badge alternated CITY/CLASS on an unchanged
    // street (user, 2026-10-13: "why city and class jumping, u forgot what is
    // city?").
    final base = statutoryRoad(
      name: street,
      highway: hw,
      label: hw,
      vehicle: vehicleType,
      // ⭐ The road FORM comes from the recording too. Left at its defaults every
      // road looked two-way, so the motorbike ceiling capped a đường đôi's Waze
      // limit to 50 (Lũy Bán Bích) — see ReplayFix.divided.
      oneway: f.oneway,
      lanes: f.lanes,
      divided: f.divided,
      urban: urban,
    );
    // ⭐ The posted-limit layer is applied BEFORE publishing, exactly as the live
    // path does (_refreshRoad → _withPostedLayer). The replay used to publish the
    // bare CLASS default and let [_correctSpeedFromWaze] fix it a tick later, so
    // the dial read "CLASS" and the callout announced the class number — 30 on the
    // Ấp Bắc service lane where the Waze segment says 50 — with the segment only
    // winning on the NEXT fix (user, 2026-09-29: "no waze segment used in announce
    // and show the speed").
    final info = at == null ? base : await _withPostedLayer(base, at);
    // ⛔ `_roadOsm` gets the CLASS baseline, never [info]. It is the value the
    // posted-limit layer falls back to when it has nothing for this road
    // (_correctSpeedFromWazeInner: "back to class 50"), so storing a
    // layer-derived value here made that fallback answer with the LAYER's own
    // last number and the dial never let go of it.
    //
    // Measured on the 2026-09-29 08:37 drive at the Ba Vân junction: the
    // recording still names the road "Lũy Bán Bích" for 12 consecutive fixes,
    // but the layer has NO
    // Lũy Bán Bích record within 200 m there — its nearest is 196 m back at
    // 60 km/h — while a "Ba Vân" 50 record sits 11.7-15.8 m from the car. The
    // name veto (correctly) refused to post another street's record, so the
    // lookup returned nothing, the fallback held `_roadOsm` = "segment 60", and
    // the dial showed 60 for the whole stretch on a road the layer says is 50
    // (user, 2026-09-29: "Ba Vân have waze segment 50 why i still see it show
    // 60"). With the baseline stored instead, the same fallback lands on the
    // road's own statutory value.
    _roadOsm = base;
    debugPrint('ROAD: replay "${_roadInfo?.name ?? ''}" -> "$street" '
        '($hw, ${urban ? 'in town' : 'outside town'}, ${info.speedLimit}'
        '${info.src.isEmpty ? '' : ', src=${info.src}'})');
    _lastRoadPublishPos = at;
    _roadNameGate.reset();
    setNavState(() => _roadInfo = _gateValue(info, at: at));
  }

  /// Restart the GPS stream shortly after it ends/errors — some devices
  /// drop the stream, which would silently freeze both the UI updates and
  /// the off-route re-routing.
  void _restartGps() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startGps();
    });
  }

  /// Min metres the car must travel before the current road is re-resolved.
  ///
  /// The old gate was TIME-only (2 s). That left the PREVIOUS street's posted
  /// limit on screen after the car had already turned onto a new one — up to
  /// ~28 m of stale limit at 50 km/h, and worse because the timestamp was
  /// consumed before the async work, so a cycle skipped by `_roadLoading`
  /// still burned the whole window. The on-device GraphHopper lookup is
  /// instant and offline, so re-querying on distance is cheap.
  static const double _roadRequeryM = 8;

  /// The route's own names for where the car is: the current step and the two
  /// ahead. A road match naming something else is off-route (see [pickRoadName]).
  Set<String> _routeNames() {
    final nav = _lastNav;
    if (nav == null) return const {};
    // The engine's "carry on" text is NOT a street name: feeding it in as one
    // made every real street disagree with the route, which vetoed every posted
    // limit on a route whose steps have no names (see [routeRoadNames]).
    return routeRoadNames(
      [nav.text, nav.nextText, nav.nextNextText],
      placeholder: kContinuePlaceholder,
    );
  }

  /// Does the road NAME we are holding come from a source independent of the app
  /// itself?
  ///
  /// Kept as the answer to "may the name we hold veto the layer?": a veto needs
  /// evidence about the road the car is on. On the phone the road matcher
  /// supplies it (graph/Overpass). In a replay it does not — `_refreshRoad`
  /// returns early and the only name is `ReplayFix.street`, which `TripLogger`
  /// wrote from the name the app had PUBLISHED (`_logFix`: `streetName: r?.name`),
  /// so a veto built from it vetoes with the app's own past error.
  ///
  /// ⚠ The two paths are NOT allowed to diverge any more. This is used only to
  /// decide how much the name may narrow the layer's answer — the geometric rule
  /// that actually fixed the wrong-road case lives in the shared lookup
  /// (`_pickWithContinuity`) and in [layerLimitMatchesNames]'s `ridden`, so the
  /// phone and the simulator run the same decision (user, 2026-09-29: "but it is
  /// the app problem not web").
  bool get _noIndependentRoadName => _startedReplay;

  /// The route's names as VETO EVIDENCE — empty when the route was built by a
  /// replay.
  ///
  /// `routeFromTrack` names a replay's steps out of the recording's own street
  /// names, so in a replay the route is the old build's output too (see
  /// [_noIndependentRoadName]) and it cannot say which road the car is on.
  Set<String> _routeEvidence() =>
      _noIndependentRoadName ? const <String>{} : _routeNames();

  /// The name the publisher would settle on for [candidate] right now.
  ///
  /// Uses the veto only: the hysteresis can DELAY a change, never force one, so
  /// a caller can ask "would this candidate be overruled?" before publishing.
  String _settledName(String candidate) {
    final cur = _roadInfo?.name ?? '';
    final names = _routeEvidence();
    return pickRoadName(
      current: cur,
      candidate: candidate,
      candidateOnRoute: names.any((n) => sameRoad(n, candidate)),
      currentOnRoute: names.any((n) => sameRoad(n, cur)),
    );
  }

  /// The route's own name for the step the car is in, or '' when the engine has
  /// none (a blank name or its "carry on" placeholder).
  String get _routeCurrentName {
    final t = _lastNav?.text ?? '';
    if (t.trim().isEmpty || t == kContinuePlaceholder) return '';
    return t;
  }

  String get _vetoStreet {
    // ⚠ The name we hand the layer as `expectStreet` narrows WHICH record it may
    // answer from, and in a replay the only name available is
    // `ReplayFix.street` — the name the app had PUBLISHED, i.e. the old build's
    // own output (see [_noIndependentRoadName]). Passing it would test the old
    // bug against itself. The device passes the matcher's name here; the fix for
    // a wrong one lives in the shared lookup (`_pickWithContinuity`), which is
    // why the same decision is exercised from both sides.
    if (_noIndependentRoadName) return '';
    return vetoStreetFor(
      osmName: _roadOsm?.name ?? '',
      shownName: _roadInfo?.name ?? '',
      routeNames: _routeEvidence(),
      routeCurrent: _routeCurrentName,
    );
  }

  bool _layerNameAgrees(String? segmentName, {bool ridden = false}) {
    // Every name we already know for the road under the car; see
    // [layerLimitMatchesNames] for the rule, and why an empty set must not veto
    // and why a segment the car is RIDING (rather than crossing) always passes.
    return layerLimitMatchesNames(
      segmentName: segmentName,
      settled: _roadInfo?.name ?? '',
      osmName: _roadOsm?.name ?? '',
      routeNames: _routeEvidence(),
      ridden: ridden,
    );
  }

  /// Publish a matched road, through the route veto and the change hysteresis.
  ///
  /// The matcher resolves the road from geometry alone and names a road that is
  /// not the one under the car on ~48% of fixes (median 119 m away, when the
  /// correct way is 4 m — audited over the 2026-09-21 drive). The name, the class
  /// and therefore the built-up 50/60 limit all follow that road, so two local
  /// corrections are applied here:
  ///   * a name that appears on the ROUTE outranks one that does not;
  ///   * a name CHANGE must be confirmed (or 30 m driven) before it shows.
  void _publishRoad(RoadInfo next, {LatLng? at, bool ridden = false}) {
    final cur = _roadInfo;
    if (!next.fromLayer && next.name.trim().isNotEmpty) {
      _roadOsm = next;
    } else if (next.fromLayer && next.name.trim().isNotEmpty) {
      if (_roadOsm == null || !sameRoad(_roadOsm!.name, next.name)) {
        _roadOsm = RoadInfo(
          name: next.name,
          highway: next.highway,
          label: next.label,
          urban: next.urban,
          speedLimit: effectiveLimit(
            next.highway.isEmpty ? 'unclassified' : next.highway,
            vehicle: vehicleType,
            // ⚠ oneway/lanes too: dividedForm() counts a one-way way with ≥2
            // motor lanes as a đường đôi, so leaving them out here computed the
            // TWO-WAY class value for a divided road — and this value is what
            // "layer has nothing for X — back to class" publishes.
            oneway: next.oneway,
            lanes: next.lanes,
            urban: next.urban,
            divided: next.divided,
          ),
          oneway: next.oneway,
          lanes: next.lanes,
          divided: next.divided,
          // ⚠ NOT the default `true`. This road exists because the LAYER renamed
          // us to a street we have no tags for, so its form was copied from the
          // road we were on — which is exactly the "previous road's form must not
          // bleed over" case. Inheriting `true` here made the published road a
          // "known hai chiều" again, so the NEXT layer value for the same street
          // was re-clamped to the two-way 50 — the 60/50 flap arriving from the
          // other writer (see `formIsKnown`).
          formKnown: false,
          src: next.urban ? srcCity : srcClass,
        );
      }
    }
    if (cur == null) {
      setNavState(() => _roadInfo = next);
      _lastRoadPublishPos = at;
      return;
    }
    final names = _routeEvidence();
    // ⭐ A segment the car is RIDING may rename the road even when the ROUTE says
    // otherwise.
    //
    // [pickRoadName] lets a name that appears on the route outrank one that does
    // not, because the road matcher is unreliable — but a segment the car is
    // riding is not the matcher, and the route's own step names are the PLANNER's
    // guess at the same question. Measured on the 2026-09-29 08:37 drive, the
    // device held "Trương Công Định" for 29 fixes while riding Trường Chinh (the
    // segment 4-8 m away, 1-17° off the car's heading), so the route veto would
    // have kept the wrong name on screen even after the lookup stopped answering
    // from the wrong road.
    var name = (ridden && next.name.trim().isNotEmpty)
        ? next.name
        : pickRoadName(
            current: cur.name,
            candidate: next.name,
            candidateOnRoute: names.any((n) => sameRoad(n, next.name)),
            currentOnRoute: names.any((n) => sameRoad(n, cur.name)),
          );
    if (!sameRoadSpelling(name, cur.name)) {
      final moved = (at == null || _lastRoadPublishPos == null)
          ? 0.0
          : distanceMeters(_lastRoadPublishPos!, at);
      if (!_roadNameGate.accept(
        current: cur.name,
        candidate: name,
        movedM: moved,
        // ⭐ [navNow], not [DateTime.now]. The gate counts OBSERVATIONS, and
        // "closer together than 400 ms is one observation" is a statement about
        // the clock the observations are stamped with. The replay hands the sim
        // fixes at 4× (≈330 ms of wall time apart) while the fixes themselves
        // are 1-3 s apart, so a wall clock read every consecutive fix as "the
        // same fix": _count never reached 2 and a LAYER-driven rename could
        // never be published at all. Measured on the 2026-09-29 08:37 drive, the
        // car turned onto Trường Chinh at fix 292, the layer answered
        // "Trường Chinh 60" from fix 293 (4.6-8.2 m away, 1-11° off the car's
        // heading), and the name on screen never became Trường Chinh — it jumped
        // Trương Công Định → Ấp Bắc at fix 314 and skipped the whole 15-fix
        // stretch (user: "investigate why it slow to get Trường Chinh street").
        at: navNow(),
      )) {
        name = cur.name;
      }
    } else {
      // A different spelling of the road already on screen is not a change:
      // keep the spelling the driver has been reading (and do not let it reset
      // the pending change for the road we might really be on).
      name = cur.name;
      _roadNameGate.reset();
    }
    final out = name == next.name ? next : next.copyWith(name: name);
    setNavState(() => _roadInfo = _gateValue(out, at: at));
    _lastRoadPublishPos = at;
  }

  /// The value/class signature the [_roadValueGate] confirms: the number on the
  /// chip, the class its label shows, and where both came from.
  String _valueSig(RoadInfo r) =>
      '${r.speedLimit}|${r.highway}|${r.urban}|${r.src}';

  /// Hold the road's CLASS/limit when it changes but the NAME does not.
  ///
  /// The name-change path has had hysteresis for a long time
  /// ([RoadNameHysteresis]); the VALUE had none, so a road that briefly resolves
  /// with another road's class repaints the limit for exactly one fix. Measured
  /// on the 2026-10-09 00:12 sim: `fix 77 hw=trunk lim=60 src=city` and straight
  /// back to `hw=unclassified lim=50` on fix 78 (same at 103/172/248) — the car's
  /// road momentarily resolving as the trunk road it was crossing. The driver
  /// sees the NUMBER on the chip jump (user, 2026-10-11: "when in intersection we
  /// have speed jumping").
  ///
  /// ⛔ LAYER values are never gated: a Waze/VietMap answer is the value the
  /// driver trusts and must land immediately — gating it would re-open the
  /// 2026-09-24 "the limit changes too slowly" bug. Only a non-layer
  /// (city / class / osm) change is confirmed, and only while the road NAME is
  /// unchanged, because a name change is a real move and is gated above.
  RoadInfo _gateValue(RoadInfo next, {LatLng? at}) {
    final cur = _roadInfo;
    if (cur == null) {
      _roadValueGate.reset();
      _lastValuePublishPos = at;
      return next;
    }
    // A different road, or either side from the layer: no gate.
    if (!sameRoadSpelling(next.name, cur.name) ||
        cur.fromLayer ||
        next.fromLayer) {
      _roadValueGate.reset();
      _lastValuePublishPos = at;
      return next;
    }
    final a = _valueSig(cur);
    final b = _valueSig(next);
    if (a == b) {
      _roadValueGate.reset();
      _lastValuePublishPos = at;
      return next;
    }
    final lastPos = _lastValuePublishPos;
    final moved = (at == null || lastPos == null)
        ? 0.0
        : distanceMeters(lastPos, at);
    if (_roadValueGate.accept(
      current: a,
      candidate: b,
      movedM: moved,
      at: navNow(),
      same: (x, y) => x == y,
    )) {
      _lastValuePublishPos = at;
      return next;
    }
    // Not confirmed yet: keep the number that is already on screen.
    return cur;
  }

  /// Floor between queries so GPS jitter while stationary can't spin.
  static const Duration _roadRequeryMinGap = Duration(milliseconds: 600);

  /// Idle fallback: refresh on this cadence even when not moving, so a stopped
  /// car still picks up an updated road/limit underneath it.
  static const Duration _roadRequeryIdleGap = Duration(seconds: 2);

  /// Look up the current road (type + speed limit). Prefers the on-device
  /// GraphHopper graph (instant + offline); falls back to Overpass.
  ///
  /// [pos] is the raw GPS fix — the car's ACTUAL position. [snapped] (the
  /// route-projected point) is only a fallback: resolving the road at the
  /// snapped point made the chip keep the road the car had just left for as long
  /// as the projection lagged (at a junction with 15-20 m of GPS error the
  /// projection can sit on the previous leg for seconds), and every road
  /// attribute — name, class, therefore the built-up 50/60 limit — came with it.
  Future<void> _refreshRoad(LatLng pos, {LatLng? snapped}) async {
    if (_startedReplay) return;
    final now = DateTime.now();
    final last = _lastRoadQuery;
    final lastPos = _lastRoadQueryPos;
    final elapsed = last == null
        ? const Duration(days: 1)
        : now.difference(last);
    // Distance travelled since the last query, compared SQUARED so no sqrt
    // (and no extra import) is needed. Longitude is scaled by cos(lat) for
    // the ~10-11° N latitudes this app runs at.
    var moved2 = double.infinity;
    if (lastPos != null) {
      final dLat = (pos.latitude - lastPos.latitude) * 111320.0;
      final dLng = (pos.longitude - lastPos.longitude) * 109000.0;
      moved2 = dLat * dLat + dLng * dLng;
    }
    final movedEnough = moved2 >= _roadRequeryM * _roadRequeryM;
    final due =
        (elapsed >= _roadRequeryMinGap && movedEnough) ||
        elapsed >= _roadRequeryIdleGap;
    if (!due) return;
    _lastRoadQuery = now;
    _lastRoadQueryPos = pos;
    // On-device graph: no network, no server latency.
    if (OfflineRouter.instance.isLoaded) {
      try {
        // Resolve at the RAW fix — where the car actually is. The
        // route-projected point is only a fallback (a gap in the graph under
        // the car): at a junction the projection can still sit on the leg the
        // car has just left, and the name, the class and therefore the built-up
        // 50/60 limit would all come from that other road.
        var look = pos;
        var r = await _roadInfoFromGraph(look);
        if (r == null && snapped != null && snapped != pos) {
          look = snapped;
          r = await _roadInfoFromGraph(look);
        }
        if (r != null && mounted) {
          // Apply the posted-limit layer to the fresh road info BEFORE it is
          // published. Publishing the bare graph value and letting the NEXT
          // fix's layer lookup correct it (~1 s later) is exactly what the
          // driver saw as a lagging limit: every road change flashed the
          // statutory class default first, then jumped to the real posted
          // value (user: "the speed limit still slow, can u make it instant
          // update like waze segment").
          final merged = await _withPostedLayer(r, look);
          if (!mounted) return;
          _publishRoad(merged, at: look);
          // VN rarely tags maxspeed, so the graph limit is usually only the
          // statutory default. When ONLINE, correct it in the background from
          // OSM's REAL `maxspeed` tag — the graph value shows instantly and
          // the correction overwrites it ~1 s later (never blocks the UI).
          // Skipped when the layer already answered: that value is authority
          // (`applyPostedLayer` sets `maxspeed`), so the Overpass trip would
          // only be able to tighten it, at the cost of a network round-trip.
          if (merged.maxspeed == null && !_offline && !forceOffline) {
            unawaited(_correctSpeedFromOsm(pos));
          }
          // The posted-limit lookup itself runs on EVERY fix in the nav tick
          // (see _signAhead/_correctSpeedFromWaze call site) — doing it here
          // too would just duplicate it behind this 600 ms/8 m throttle.
          _maybeWarnMotorwayProhibited();
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
        heading: _heading,
      );
      if (!mounted || r == null) return;
      // Same rule as the graph path: the posted layer is applied BEFORE the
      // road is published, so the limit never lags a road change.
      final merged = await _withPostedLayer(r, pos);
      if (!mounted) return;
      _publishRoad(merged, at: pos);
      _maybeWarnMotorwayProhibited();
    } catch (_) {
      // keep the last known road on failure
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
  }

  /// [road] with the posted-limit segment layer under [pos] applied, using the
  /// SAME offline lookup [_correctSpeedFromWaze] uses (Waze segment → Waze
  /// point → VietMap point, O(1) after load).
  ///
  /// Called when fresh road info is published so the limit is right from the
  /// first frame of a new road. It also makes the two writers race-safe: both
  /// publish road+layer, so whichever lands last cannot leave a bare class
  /// default on screen.
  Future<RoadInfo> _withPostedLayer(RoadInfo road, LatLng pos) async {
    if (road.name.trim().isNotEmpty) _roadOsm = road;
    // The road on screen right now, and the value to fall back to: the one the
    // LAYER already gave for THIS road when there is one, else [road] (the
    // class rule). Hoisted out of the try so a thrown lookup keeps it too.
    final cur = _roadInfo;
    // ⛔ NO POSTED-VALUE HOLD ANY MORE (option 1, 2026-10-13).
    //
    // This used to return the value already on screen (`held`) whenever the
    // layer MISSED, bounded only by [LayerHold.maxMeters]. That kept a posted
    // 60 on the chip after the car had LEFT the 60 road (user: "go from luỹ bán
    // bích to thống nhất or some other street no waze, it keep 60 km/h"). A
    // posted limit belongs to the road it was posted on, so on a miss we now
    // publish THIS road's own value (class / statutory / OSM) instead.
    try {
      // Keep the value on screen while two parallel records of the SAME road
      // disagree (see _pickWithContinuity): without it the chip swapped 60/50
      // every second on Cộng Hòa, 2026-09-22.
      //
      // ⭐ Only for the SAME road. Handing the layer the PREVIOUS road's limit
      // kept the old road's value on the NEW one: entering Lũy Bán Bích (Waze
      // 60) from Thống Nhất (50) the lookup returned the 50 of a nearby record
      // and it was published as `src=segment` — a confident "Waze 50" that is
      // wrong (user, 2026-09-29: "waze now show wrong value").
      final keep = (cur != null && sameRoad(cur.name, road.name))
          ? cur.speedLimit
          : null;
      final hit = await lookupSpeedLimit(
        pos,
        headingDeg: _heading == 0 ? null : _heading,
        keepKmh: keep,
        expectStreet: _vetoStreet,
      );
      if (hit == null) return road;
      // Limit, layer kind and street name all come from THIS result.
      final layerKind = hit.source;
      final layerName = hit.streetName;
      // ⚠ The name check STAYS: without it the nearest segment can be a
      // CROSSING street and its value is then published for our road — measured
      // 2026-09-29 by removing it: Lũy Bán Bích (Waze 60) dropped to a crossing
      // street's 50 on 5 consecutive publishes. "If no segment follow the rule"
      // is about the FALLBACK, not about accepting another road's segment.
      //
      // A segment the car is RIDING is exempt — that IS the road under it, and
      // vetoing it here threw the answer away and kept the class value, which
      // `_correctSpeedFromWazeInner` then re-adopted on the very next fix, so the
      // value flickered between the two. This path is not simulator-only: the
      // 8 m graph refresh and the replay publisher both come through here.
      if (!_layerNameAgrees(layerName, ridden: hit.aligned)) {
        return road;
      }
      // The layer answered for THIS road from HERE: that is the anchor the hold
      // is measured from (see [LayerHold]).
      _layerHold.note(layerName ?? road.name, pos);
      return applyPostedLayer(
        road,
        kmh: hit.limit,
        vehicle: vehicleType,
        layerSrc: layerKind,
        name: layerName,
        inTown: await _townAt(pos),
      );
    } catch (_) {
      return road; // no layer data → this road's own value
    }
  }

  /// Is the car in a built-up area (khu đông dân cư)?
  ///
  /// When a physical boundary sign (R.420 / R.421) has been reached on the route,
  /// [_inTownBySign] holds the sign's legal authority. Otherwise, falls back to
  /// [builtUpRuleApplies] (POI / road segment density) cached per 150 m as the
  /// cold-start seed.
  Future<bool> _townAt(LatLng pos) async {
    if (_inTownBySign) return _inTown;
    final prev = _inTownPos;
    if (prev != null && distanceMeters(prev, pos) < 150) return _inTown;
    _inTownPos = pos;
    _inTown = await builtUpRuleApplies(pos, hasPosted: false);
    return _inTown;
  }

  /// Update the current road's statutory speed limit when crossing a built-up
  /// boundary sign (R.420 / R.421).
  void _updateRoadForTownChange(bool inTown, {LatLng? at}) {
    final cur = _roadInfo;
    if (cur == null) return;
    if (!cur.fromLayer) {
      final newLimit = effectiveLimit(
        cur.highway.isEmpty ? 'unclassified' : cur.highway,
        vehicle: vehicleType,
        oneway: cur.oneway,
        lanes: cur.lanes,
        urban: inTown,
        divided: cur.divided,
      );
      final updated = cur.copyWith(
        urban: inTown,
        speedLimit: newLimit,
        src: inTown ? srcCity : srcClass,
      );
      _publishRoad(updated, at: at);
    } else {
      final updated = cur.copyWith(urban: inTown);
      _publishRoad(updated, at: at);
    }
  }

  /// Background speed-limit correction: re-fetch road info from OSM (which
  /// reads the real `maxspeed` tag when tagged) and overwrite the limit the
  /// offline graph only estimated via the statutory class default. Best-effort
  /// — on failure the graph/statutory value is kept.
  Future<void> _correctSpeedFromOsm(LatLng pos) async {
    if (_roadLoading) return; // don't stack with the main fetch
    setNavState(() => _roadLoading = true);
    try {
      final r = await fetchRoadInfo(
        pos,
        vehicle: vehicleType,
        heading: _heading,
      );
      if (mounted && r != null) _publishRoad(r, at: pos);
    } catch (_) {
      // keep the current (graph/statutory) value
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
  }

  /// Real posted speed-limit correction from the bundled Waze/VietMap point
  /// layer (offline, nationwide, instant — no network). The on-device graph
  /// can only estimate the statutory class default; Waze/VietMap carry the
  /// actual posted sign, so when one is within a few metres of the car its
  /// value wins. Best-effort: on no match the graph/statutory value stands.
  ///
  /// [raw] is the physical GPS fix; [snapped] the route-projected point. The
  /// posted limit is looked up at [raw] FIRST because that is where the car
  /// actually is: measured on the 2026-09-20 drive, the route-snapped point
  /// missed the segment that exists at the raw fix on 178 fixes (7.4%) — the
  /// chip stayed on the class default for up to 25 s on Tân Thành, Bàu Cát,
  /// Vân Côi, Phan Sào Nam, Đồng Đen, Trương Công Định, Cách Mạng Tháng Tám
  /// and Lý Thường Kiệt. [snapped] is used only when [raw] finds nothing.
  Future<void> _correctSpeedFromWaze(LatLng raw, {LatLng? snapped}) async {
    // NOTE: deliberately NO `_roadLoading` gate any more. It used to return
    // early while the graph/Overpass road query was in flight — which is
    // precisely when the car has just changed road and the new segment's
    // limit is needed, so the ONE source that can answer instantly was muted
    // at the only moment it mattered. The layer lookup is offline and O(1);
    // only the OSM re-fetch has to avoid stacking (see _correctSpeedFromOsm).
    //
    // The old `_wazeCorrecting` re-entry lock is gone too: it existed because
    // the limit and its street name came from two module globals that the next
    // lookup overwrote, so overlapping corrections could pair one segment's
    // limit with another's street. [lookupSpeedLimit] returns both atomically,
    // so an overlap is now harmless — and corrections are no longer dropped.
    await _correctSpeedFromWazeInner(raw, snapped: snapped);
  }

  Future<void> _correctSpeedFromWazeInner(LatLng pos, {LatLng? snapped}) async {
    // The value on screen is the continuity hint (see _pickWithContinuity):
    // two Waze records of one road sit 2-3 m apart with different values and
    // identical names after folding, and without the hint the chip swaps
    // between them every fix (Cộng Hòa 60/50, 2026-09-22 drive).
    final keep = _roadInfo?.speedLimit;
    final curName = _vetoStreet;
    var hit = await lookupSpeedLimit(
      pos,
      headingDeg: _heading == 0 ? null : _heading,
      keepKmh: keep,
      expectStreet: curName,
    );
    // What went in and what came back, so a '-' on the dial can be explained
    // from a log instead of guessed at. Throttled: the first few fixes and then
    // every 50th.
    _layerLogs++;
    if (_layerLogs <= 3 || _layerLogs % 50 == 0) {
      final roadName = _roadInfo?.name ?? '';
      debugPrint(
        'LAYER: ${hit == null ? 'miss' : '${hit.limit} via ${hit.source} '
            'street="${hit.streetName}" seg=${hit.segmentId} '
            'agrees=${_layerNameAgrees(hit.streetName, ridden: hit.aligned)}'}'
        ' @${pos.latitude.toStringAsFixed(4)},${pos.longitude.toStringAsFixed(4)}'
        ' hdg=${(_heading ?? 0).toStringAsFixed(0)} keep=$keep expect="$curName"'
        ' road=${roadName.isEmpty ? '-' : roadName}'
        ' routes=${_routeNames().take(3).join('|')}'
        '${_noIndependentRoadName ? ' veto=none (replay)' : ''}',
      );
    }
    var usedSnapped = false;
    if (hit == null && snapped != null && snapped != pos) {
      hit = await lookupSpeedLimit(
        snapped,
        headingDeg: _heading == 0 ? null : _heading,
        keepKmh: keep,
        expectStreet: curName,
      );
      usedSnapped = hit != null;
    }
    // Limit, layer and street all come from THIS result — nothing to re-read
    // from module globals, so a lookup that runs meanwhile cannot rewrite any
    // of the three out from under us.
    final lim = hit?.limit;
    final layerKind = hit?.source;
    final wazeName = hit?.streetName;
    if (!mounted) return;
    final cur = _roadInfo;
    if (cur == null) {
      // The layer needs neither the on-device graph nor the network, so it must
      // not wait for a road lookup that may never answer: the web build gets
      // 504s from Overpass, and the phone's graph stops at the downloaded area.
      // Publish what the segment knows rather than dropping it — dropping it is
      // why the dial read '-' for the whole 1,686 km QL1A fixture.
      // riding it, so the same exemption applies as everywhere else.
      if (lim != null &&
          _layerNameAgrees(wazeName, ridden: hit?.aligned ?? false)) {
        final only = applyPostedLayer(
          RoadInfo(name: '', highway: '', label: '', speedLimit: 0),
          kmh: lim,
          vehicle: vehicleType,
          layerSrc: layerKind ?? srcSegment,
          name: wazeName ?? '',
          inTown: await _townAt(pos),
        );
        debugPrint(
          'ROAD: no road lookup yet — segment says ${only.speedLimit} km/h'
          '${(wazeName ?? '').isEmpty ? '' : ' on "$wazeName"'}',
        );
        // An UNNAMED segment cannot anchor the hold (there is no road name to
        // match against later), so only a named one is remembered.
        if (wazeName != null && wazeName.trim().isNotEmpty) {
          _layerHold.note(wazeName, pos);
        }
        _publishRoad(only);
      }
      return;
    }
    // Waze is now the PRIMARY source for the street NAME: it is a geometric
    // lookup against the segment under the car, so it flips the instant the car
    // crosses a boundary. GraphHopper stays the offline option for the road
    // CLASS, which the statutory 50/60 rules need and which Waze's numeric
    // roadType cannot express.
    //
    // This is the fix for "the speed shown is not the correct street": the old
    // code published a FRESH limit while explicitly keeping `name: cur.name`,
    // so the chip paired the new limit with the PREVIOUS street's name until
    // the throttled road query caught up.
    final name = (wazeName != null && wazeName.isNotEmpty)
        ? wazeName
        : cur.name;
    // The segment's street and its posted value must describe the SAME road.
    // Measured on the 2026-09-21 drive, 26 fixes had a settled name that
    // disagreed with the winning segment's street and 16 of those changed the
    // limit shown (display 'Lũy Bán Bích' with a 50 from the crossing
    // 'Độc Lập'; display 'Thống Nhất' with a 60 from 'Lũy Bán Bích'). Only the
    // NAME went through the veto — the value travelled with the segment record.
    final limitUsable = _layerNameAgrees(wazeName, ridden: hit?.aligned ?? false);
    // ⭐ The layer just answered for the road on screen, from HERE: that is the
    // anchor a later MISS is measured from (see [LayerHold]). Noted BEFORE the
    // "nothing changed, return" shortcut below, or a value the layer keeps
    // re-confirming would never refresh its anchor — and the hold would then
    // look stale 150 m into a stretch the layer covers perfectly.
    if (lim != null && limitUsable) _layerHold.note(name, pos);
    if (lim == null || !limitUsable) {
      if (lim != null) {
        debugPrint('ROAD: dropped layer limit $lim from "$wazeName" — the road '
            'on screen is "${_settledName(name)}"');
      }
      final osm = _roadOsm;
      RoadInfo fallbackRoad;
      // ⭐ Did the road we are falling back to come from the HEADING-CHECKED
      // graph lookup? If so it is the road the car is riding, which is exactly
      // the evidence the route veto must not overrule (see the `ridden:`
      // argument below).
      var fallbackRidden = false;
      if (osm != null && sameRoad(osm.name, name)) {
        fallbackRoad = osm;
      } else {
        // The road name changed but the segment layer has no record here.
        // Re-query the on-device graph for the NEW road's real attributes
        // (highway, divided, lanes) instead of guessing 'unclassified' — a
        // blind guess gets the wrong speed on any road whose form differs from
        // the default (e.g. turning onto a divided highway: guess gives 50
        // undivided, real data gives 60 divided).
        final graphRoad = await _roadInfoFromGraph(pos);
        if (graphRoad != null && graphRoad.name.trim().isNotEmpty) {
          fallbackRoad = graphRoad;
          // `_roadInfoFromGraph` calls `OfflineRouter.roadInfo(pos, headingDeg:
          // _heading)`, which REJECTS an edge running across the car's path —
          // the same alignment test the Waze path passes as `hit.aligned`. A
          // named road that survived it is the road under the car, so its name
          // is riding evidence. (A same-key spelling variant still loses to the
          // spelling on screen — `_publishRoad` keeps it either way, so this
          // cannot re-open the Cộng Hòa ⇄ Cộng Hoà churn.)
          fallbackRidden = true;
        } else {
          final urban = await _townAt(pos);
          fallbackRoad = RoadInfo(
            name: name,
            highway: 'unclassified',
            label: '',
            urban: urban,
            speedLimit: effectiveLimit(
              'unclassified',
              vehicle: vehicleType,
              urban: urban,
            ),
            // We know NOTHING about this street's form — no graph way, no tags.
            // The default `true` read that silence as "hai chiều", so once this
            // road was published the next layer value for the same street was
            // clamped to the two-way 50 while the road-refresh writer used the
            // zone ceiling (60 in town): the same flap, one fix apart.
            formKnown: false,
            src: urban ? srcCity : srcClass,
          );
        }
        _roadOsm = fallbackRoad;
      }
      // ⛔ THE POSTED-VALUE HOLD IS GONE (option 1, 2026-10-13).
      //
      // It read: hold the published layer value while `sameRoad(cur.name, name)`
      // and within [LayerHold.maxMeters]. But on a miss `name` IS `cur.name`
      // (there is no segment to name the road), so the name test could never
      // fail — the hold was purely a 300 m timer, and it kept a posted 60 on a
      // road the layer knows nothing about (user: "go from luỹ bán bích to
      // thống nhất or some other street no waze, it keep 60 km/h"). A posted
      // limit belongs to the road it was posted on: on a miss we publish
      // [fallbackRoad] — this road's own OSM / statutory value — instead.
      //
      // If this proves to stutter at layer gaps, the fix is a hold that must be
      // EARNED (the freshly resolved road must still match the posted one), not
      // a longer timer.

      if (cur.fromLayer ||
          cur.speedLimit != fallbackRoad.speedLimit ||
          cur.src != fallbackRoad.src) {
        debugPrint('ROAD: layer has nothing for "${fallbackRoad.name}" — back to '
            '${fallbackRoad.src} ${fallbackRoad.speedLimit} (was ${cur.src} ${cur.speedLimit})'
            '${fallbackRidden ? ' [ridden]' : ''}');
        // ⭐ [ridden]: this publish was ADOPTING a new road (the layer had
        // nothing for the one under the car), and when that road came from the
        // heading-checked graph the car is demonstrably riding it — so the
        // route veto must not overrule it.
        //
        // ⛔ Without it the veto pinned the road we had LEFT: it holds
        // `current` whenever the route's step names contain the old road and
        // not the new one, which is exactly the state at a junction where the
        // route's step still spans the road being left. Measured on the
        // 2026-10-08 17:40 drive — the Waze Lũy Bán Bích segment (60) ends at
        // the Thống Nhất corner, this fallback ran from fix 10:52:05, and the
        // chip published "Lũy Bán Bích / residential / two-way / 50" for TEN
        // fixes: the new road's class, form and limit, wearing the old road's
        // name (user: "thống nhất is still luỹ bán bích"). Thống Nhất has no
        // Waze segment at all, so this path IS the one that has to name it.
        _publishRoad(fallbackRoad, at: pos, ridden: fallbackRidden);
        return;
      }
      // No posted limit for THIS road: still adopt a better name when the layer
      // has one, so the label can catch up independently of the limit — but
      // only through the route veto + hysteresis (a segment the car is not on
      // must not rename the road; see lib/core/road_match.dart).
      if (name == cur.name) return;
        debugPrint('ROAD: waze street "$name" (was "${cur.name}")');
      _publishRoad(cur.copyWith(name: name), at: pos,
          ridden: hit?.aligned ?? false);
      return;
    }
    // The Waze value IS the authority for the limit (applyPostedLayer): our
    // own class guess (service 30, living_street 20) must not clamp it, and the
    // only thing that may is the vehicle's legal maximum in this context — see
    // vehicleCeiling / effectiveLimit.
    final next = applyPostedLayer(
      cur,
      kmh: lim,
      vehicle: vehicleType,
      layerSrc: layerKind ?? srcSegment,
      name: name,
      inTown: await _townAt(pos),
    );
    if (next.speedLimit == cur.speedLimit && next.name == cur.name) return;
    debugPrint(
      'ROAD: waze limit=$lim -> ${next.speedLimit} (was ${cur.speedLimit}) '
      'street="${next.name}" ${cur.highway} from=${usedSnapped ? 'snapped' : 'raw'}',
    );
    // From here a speed sign may only tighten this value, never raise it
    // (signLimitInForce), and the widget badge names the layer behind it.
    //
    // [at] is the FIX position: without it the hysteresis sees `moved == 0` and
    // the 30 m confirmation escape (RoadNameHysteresis.confirmMeters) can never
    // fire on this path, so a rename would depend on the count alone.
    _publishRoad(next, at: pos, ridden: hit?.aligned ?? false);
  }

  /// Xe mô tô is PROHIBITED on đường cao tốc (VN road law). The route planner
  /// still lets a motorbike ride the car network (OSRM has no motorbike
  /// profile), so when the current road is a motorway the driver must be told
  /// they can't be there. Warn once per entry; re-arm once back on a normal
  /// road.
  void _maybeWarnMotorwayProhibited() {
    if (!_voiceOn || !_voiceReady) return;
    if (!_navigating && !_simulating) return;
    final hw = _roadInfo?.highway ?? '';
    final onMotorway = hw == 'motorway' || hw == 'motorway_link';
    if (vehicleType == 'motorbike' && onMotorway) {
      if (_motorwayWarned) return;
      _motorwayWarned = true;
      const phrase =
          'Chú ý! Xe mô tô không được phép đi vào đường cao tốc. Xin thoát cao tốc khi có thể.';
      _voice.speak(phrase, priority: VoiceGuide.priorityHigh);
      unawaited(
        NavForegroundService.instance.notifyProhibition(
          '🚫 Cấm xe mô tô',
          phrase,
        ),
      );
      debugPrint('MOTORWAY: motorbike prohibited — warned once');
    } else if (!onMotorway) {
      _motorwayWarned = false; // back on a normal road — re-arm
    }
  }

  /// Road info straight from the on-device graph (nearest edge), with the
  /// same Vietnamese statutory defaults as the Overpass path.
  Future<RoadInfo?> _roadInfoFromGraph(LatLng pos) async {
    final g = await OfflineRouter.instance.roadInfo(
      pos,
      // The car's heading, so the graph can reject an edge running across the
      // car's path — the same guard the Overpass path has (headingPenalty).
      headingDeg: _heading == 0 ? null : _heading,
    );
    if (g == null) return null;
    debugPrint('ROAD: graph highway=${g['highway']} maxspeed=${g['maxspeed']}');
    final highway = (g['highway'] ?? '') as String;
    if (highway.isEmpty) return null;
    // The graph rarely carries a real `maxspeed`, so its value is the class
    // default — which is the RURAL one (primary 80 for a car / 60 for a mô tô).
    // Inside a town that is wrong: the built-up rule caps it at 50 (60 on a
    // đường đôi). POI density decides which table applies; a posted value
    // (graph maxspeed or a Waze segment) always wins over it.
    final urban = await _townAt(pos);
    // ⭐ Shared with the standalone overlay, so the two badges cannot disagree
    // about the road class, the form or the zone (see [roadInfoFromGraphMap]).
    return roadInfoFromGraphMap(g, vehicle: vehicleType, urban: urban);
  }

  /// Feed the active trip logger (real GPS fixes).
  void _logFix(LatLng pos, double speedMps) {
    final t = _trip;
    if (t == null) return;
    final r = _roadInfo;
    final eff = _effectiveLimit;
    t.addFix(
      pos,
      speedMps: speedMps,
      heading: _heading,
      streetName: r?.name,
      highway: r?.highway,
      // Log BOTH numbers: the road's own value and the effective limit the
      // chip/voice used (plus the layer it came from) — that is what makes a
      // "voice said 60 while the screen showed 50" report verifiable offline.
      speedLimit: r?.speedLimit,
      limitEffective: eff.limit > 0 ? eff.limit : null,
      limitSource: eff.source,
      // The decision inputs, so any logged limit can be re-derived offline:
      // which layer was behind the road value, the vehicle class its table was
      // read with, and the road tags the built-up rule keys on.
      limitLayer: r?.src,
      vehicle: vehicleType,
      oneway: r?.oneway,
      lanes: r?.lanes,
      divided: r?.divided,
      urban: r?.urban,
      // ⭐ The REAL fix accuracy in metres. It was NOT passed, so TripLogger's
      // default (`accuracyM = 10`) was written for EVERY fix — the recording
      // then claims a constant 10 m and cannot answer "how good was the fix
      // here", which is exactly the question needed before choosing a segment
      // acceptance radius (user, 2026-09-29: "evaluate the gps fix, i think the
      // hdop is not that high that we need 15m?"). 0 (not yet known) keeps the
      // logger's default.
      accuracyM: _lastGpsAccuracy > 0 ? _lastGpsAccuracy : 10,
      // ⭐ The FIX's time, not the wall clock: `navNow()` is the drive clock
      // (`nav_clock.dart`), which the replay and the simulated drive both point
      // at the fix stream. Without it a run played at 8× wrote one fix per
      // WALL second — 24 fixes for a 189-fix drive (2026-10-08).
      at: navNow(),
      // The ROUTE's own name for the step the car is in, logged beside the
      // matcher's [streetName]. When they disagree the driver was on one road
      // while the chip/voice named another — the "on Trường Chinh it said
      // Hẻm 415" report — and this is the only field that can prove which
      // side was wrong from a recording.
      routeName: _routeCurrentName.isEmpty ? null : _routeCurrentName,
    );
  }

  /// Start recording a trip (no-op if one is already active).
  void _beginTrip() {
    if (_trip != null) return;
    // A run is starting: whatever was offered to continue is now the run in
    // progress, or was superseded by a different journey.
    _resumeTrip = null;
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
