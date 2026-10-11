part of '../navigation_page.dart';

/// TRACK SIMULATION — a route in, GPS points through the real pipeline, a TRIP
/// out.
///
/// ⭐ NOT the replay. They answer different questions and must not be confused:
///
///   * **Playback** (`?trip=…`, `lib/services/trip_replay.dart`) drives a
///     RECORDED drive and is handed that recording's own answers: the route is
///     the recorded track (`routeFromTrack`) and every fix's road identity is
///     injected from the recording (`_applyReplayRoad` → `ReplayFix.street`).
///     That is what makes it a playback — and why it can never test the road
///     chain: it feeds the app's own past output back in.
///   * **Simulation** (this file) is given a ROUTE and nothing else. The app
///     plans it with the real router, walks the router's own geometry to
///     synthesise the GPS stream ([synthesiseTrack]), and lets the road chain
///     decide everything:
///       - the road under the car comes from the graph/Overpass lookup and the
///         posted-limit layer, never from the input (`_startedReplay` stays
///         false, so `_applyReplayRoad` never runs and the route/name veto
///         evidence is live again);
///       - the fixes go through the real `_onGpsFix` pipeline (outlier gate,
///         heading filter, road lookup, sign adoption, built-up verdict, voice),
///         which writes the trip as it goes.
///
/// ⭐ THE POINTS ARE ON THE ROUTE BY CONSTRUCTION — they are sampled ALONG the
/// planned geometry, never supplied as a track. That is not a detail: points
/// that miss the route make the app decide the driver is off-route and REROUTE,
/// after which every lookup describes the detour instead of the road being
/// driven (the trap documented for the emulator harness in
/// navbridge-emulator-sim). The receiver's own error is then added on top by
/// [GpsSimOptions] — lateral scatter scaled to the reported accuracy,
/// speed/heading jitter, a coarse cold start, degraded and lost fixes, and rare
/// gross outliers — because clean points never exercise the outlier gate, the
/// heading filter or the 45° road-match test.
///
/// The OUTPUT is the trip document itself — the same `toTakeoutJson()` a
/// finished drive writes, i.e. the shape of `docs/trips/device/*.json`, so every
/// existing offline audit tool reads it unchanged. It is POSTed to
/// `<served origin>/__trip` for the headless driver (`tool/sim_track.py`).
///
/// Usage (served build):
///   ?sim=10.8000,106.6400,11.9400,108.4400   from → to (lat,lng,lat,lng)
///   &pace=13.9        ground speed, m/s (default 50 km/h)
///   &noise=1.0        error multiplier; 0 = a perfect receiver
///   &seed=7           repeatable noise
///   &tspeed=8         how fast to feed the synthesised drive
/// or take the endpoints from a track fixture (its OWN points are not driven):
///   ?track=/trips/ql20_corridor.json
extension _NavTrackSim on _NavigationPageState {
  // The feed speed and the car's speed are the console's settings now
  // (`simFeedSpeed` / `simDriveKmh` in nav_sim.dart) — they used to be a
  // constant here plus a URL parameter, which meant a run could not be started
  // from the app itself.

  /// The console's "Mô phỏng GPS" button, answered here.
  ///
  /// A simulation REPLACES the fix stream and the route, so it is refused while
  /// one is already running or while a replay owns the stream — half-started
  /// runs are what produced the double feed this session started with. The
  /// request is consumed either way: a queue of stale requests would fire after
  /// the run that replaced it.
  void _onSimTick() {
    final gpsRef = simTakeGpsSimRequest();
    if (gpsRef != null) {
      if (_trackSimRunning || _startedReplay) {
        debugPrint('SIM: ignoring the GPS-file request — a run is in progress');
      } else {
        unawaited(_runGpsFileSim(gpsRef));
      }
      return;
    }
    final req = simTakeTrackSimRequest();
    if (req == null) return;
    if (req.length < 2) {
      debugPrint('SIM: a simulation needs at least 2 points, got ${req.length}');
      return;
    }
    if (_trackSimRunning || _startedReplay) {
      debugPrint('SIM: ignoring the request — a run is already in progress');
      return;
    }
    unawaited(_runTrackSim(req.first, req.last));
  }

  /// `?gps=<path|url>` — a GPS TRACE in, a TRIP out, nothing else given.
  ///
  /// ⭐ THIS is the raw-input mode, and it is not a playback. What the app is
  /// handed is a list of positions and their times — no route, no road names,
  /// no limits, no manoeuvres. It plans NO route and installs no engine: every
  /// answer in the trip it writes (the road under the car, its posted limit,
  /// which layer that limit came from, the town verdict, the signs adopted, the
  /// announcements) is derived from the map data as the fixes arrive.
  ///
  ///   * `?trip=` (playback) is given the drive's own recorded answers — the
  ///     route AND each fix's road identity (`_applyReplayRoad`);
  ///   * `?sim=` / the console's route button plans a route first, so the app
  ///     knows where it is going before the first fix;
  ///   * `?gps=` (this) is given nothing but the fixes.
  ///
  /// No route means no turn-by-turn: the `manoeuvre`/`next street` callouts
  /// cannot exist without a planned step list. That is not a gap in this mode —
  /// asking for them would mean asking for the route back.
  String get _gpsSimRef =>
      kIsWeb ? (Uri.base.queryParameters['gps'] ?? '').trim() : '';

  Future<void> _maybeSimulateGps() async {
    final ref = _gpsSimRef;
    if (ref.isEmpty) return;
    await _runGpsFileSim(ref);
  }

  /// `?nav=1` or `?dest=lat,lng` — plan a route for the drive, the way a real
  /// drive has one.
  ///
  /// ⭐ WHY THIS EXISTS. Without it a trace has no step list, so turn/next-street
  /// callouts cannot happen — and the fair question is "then how does the real
  /// app ever produce them?". Because on a real drive the driver PICKED A
  /// DESTINATION: the app planned a route at the start and therefore has steps.
  /// A trace with no destination models the other real case — driving with no
  /// navigation at all — where the real app also has no steps and also makes no
  /// turn callouts. Limits, boundaries, cameras and signs are made either way.
  ///
  /// With this on, the app does what a driver does: it plans from the trace's
  /// first fix to the destination (or to the trace's own last fix), then drives
  /// **the fixes from the file**. The fixes stay independent input — they are
  /// NOT generated from the plan, which is the property that makes this a test.
  String get _gpsDestRef =>
      kIsWeb ? (Uri.base.queryParameters['dest'] ?? '').trim() : '';

  bool get _gpsNavWanted => kIsWeb && (Uri.base.queryParameters['nav'] ?? '') == '1';

  Future<void> _runGpsFileSim(String ref) async {
    final fixes = await TripReplay.load(ref);
    if (!mounted) return;
    if (fixes.length < 2) {
      debugPrint('SIM: "$ref" produced ${fixes.length} fixes — a GPS trace needs '
          'at least 2');
      return;
    }
    final tspeed = _simParam('tspeed', simFeedSpeed);
    debugPrint(
      'SIM(GPS): $ref — ${fixes.length} fixes, '
      '${replayTripDuration(fixes).inMinutes}m'
      '${replayTripDuration(fixes).inSeconds % 60}s of drive time, '
      '${(replayTripMeters(fixes) / 1000).toStringAsFixed(2)} km, fed at '
      '$tspeed×',
    );

    // ── the destination, if the caller says the driver had one.
    LatLng? dest;
    if (_gpsDestRef.isNotEmpty) {
      final parts =
          _gpsDestRef.split(',').map((s) => double.tryParse(s.trim())).toList();
      if (parts.length == 2 && parts.every((p) => p != null)) {
        dest = LatLng(parts[0]!, parts[1]!);
      } else {
        debugPrint('SIM(GPS): ?dest= must be lat,lng — got "$_gpsDestRef"');
      }
    } else if (_gpsNavWanted) {
      dest = fixes.last.point;
    }

    OsrmRoute? route;
    if (dest != null) {
      try {
        route = await fetchAnyRoute(
          <LatLng>[fixes.first.point, dest],
          profile: _routeProfile,
          avoidHighway: _avoidHighway,
          avoidFerry: _avoidFerry,
          preference: _routePreference,
          onlineTimeout: const Duration(seconds: 120),
        );
      } catch (e) {
        debugPrint('SIM(GPS): could not plan a route from the trace to $dest: $e');
      }
      if (!mounted) return;
      if (route != null && route.geometry.length >= 2) {
        debugPrint(
          'SIM(GPS): route planned — ${(route.distance / 1000).toStringAsFixed(2)} '
          'km, ${route.steps.length - 1} manoeuvres: the app now has a step '
          'list, so turn/next-street callouts CAN fire (the fixes still come '
          'from the file, not from this plan)',
        );
      }
    }
    if (route == null) {
      debugPrint('SIM(GPS): scope — NO route and NO engine are installed; roads, '
          'limits, signs, built-up and announcements are derived from the map '
          'data, so there are no manoeuvre/next-street callouts');
    }

    // The trip is recorded exactly as a live drive records one.
    _beginTrip();
    // The drive clock, so every cadence and the trip log's own thinning run on
    // fix time (see nav_clock.dart) — a fast run must write the trip a 1× drive
    // would.
    setNavClock(() => _lastGpsFixTime ?? fixes.first.at);
    if (route != null) {
      final r = route;
      setNavState(() {
        _route = r;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _planPoints = <LatLng>[fixes.first.point, dest!];
        _originOverride = fixes.first.point;
        _origin = fixes.first.point;
        _destination = dest;
        _current = fixes.first.point;
        _routeBearing = 0;
        _routeStartIndex = 0;
        _navigating = false; // _startSimulation owns the start from here
        _stops
          ..clear()
          ..add(
            TripStop(
              name: 'gps → ${dest.latitude.toStringAsFixed(4)},'
                  '${dest.longitude.toStringAsFixed(4)}',
              lat: dest.latitude,
              lng: dest.longitude,
            ),
          );
        _engine = TurnByTurnEngine(
          r,
          stopNames: _engineStopNames(r),
          maxSpeedMps: _routeProfile.legalMaxMps,
        );
      });
    }
    _trackSimRunning = true; // keeps `_startGps` off the fix stream
    final span = replayTripDuration(fixes);
    simBeginRun(
      label: 'gps ${(replayTripMeters(fixes) / 1000).toStringAsFixed(1)} km',
      ref: ref,
      speed: tspeed,
      fixes: fixes.length,
      meters: replayTripMeters(fixes),
      duration: span,
    );
    debugPrint('SIM(GPS): driving — ${fixes.length} fixes from the file');
    await _startSimulation(
      track: fixes,
      trackSpeed: tspeed,
      onFinished: () => unawaited(_finishTrackSim()),
    );
  }

  /// `lat,lng,lat,lng` — from → to. Empty when the mode is not armed.
  String get _simSpec =>
      kIsWeb ? (Uri.base.queryParameters['sim'] ?? '').trim() : '';

  /// A track fixture whose FIRST and LAST points become the endpoints. Its own
  /// points are deliberately NOT driven: they are not the route.
  String get _trackSimRef {
    if (kIsWeb) return (Uri.base.queryParameters['track'] ?? '').trim();
    return const String.fromEnvironment('SIM_TRACK').trim();
  }

  double _simParam(String name, double fallback) {
    if (!kIsWeb) return fallback;
    return double.tryParse(Uri.base.queryParameters[name] ?? '') ?? fallback;
  }

  /// Arm the mode. Called once from `initState`, next to `_maybeAutoSim`.
  ///
  /// Deliberately NOT routed through `_maybeAutoSim`: that one branches on
  /// `TripReplay.armed` and hands over to the replay, and the whole point here
  /// is that the replay machinery stays out of the way.
  Future<void> _maybeSimulateTrack() async {
    // ── 0. a route supplied by the driver, if there is one.
    //
    // ⭐ WHY a supplied route is still a SIMULATION and not a playback: a route
    // is an input a driver also has (they decided where to go, and something
    // worked out how). What defines a playback is being handed the DRIVE's own
    // answers — here nothing about the roads, limits, signs or announcements is
    // supplied: the app derives all of it from the map data as the fixes arrive.
    //
    // It exists because a headless run has no usable router: the offline graph
    // is native-only, and the public OSRM server is not reachable from the
    // browser (measured: "ROUTER: GraphHopper returned no route — next", then
    // silence). tool/sim_track.py plans the route with OSRM and serves it.
    final routeRef =
        kIsWeb ? (Uri.base.queryParameters['route'] ?? '').trim() : '';
    OsrmRoute? supplied;
    if (routeRef.isNotEmpty) {
      final body = (await http.get(Uri.base.resolve(routeRef))).body;
      final routes = parseOsrmResponse(body);
      if (!mounted) return;
      if (routes.isEmpty) {
        debugPrint('SIM: "$routeRef" is not an OSRM response with routes[0] — '
            'nothing to drive');
        return;
      }
      supplied = routes.first;
      debugPrint(
        'SIM: route SUPPLIED by the driver — '
        '${(supplied.distance / 1000).toStringAsFixed(2)} km, '
        '${supplied.steps.length - 1} manoeuvres, '
        '${supplied.geometry.length} geometry points',
      );
      // ⚠ Diagnosing a bogus endpoint: the browser once decoded this polyline
      // into a destination of 27.917,32.643 (Egypt) while the same file decoded
      // correctly in a Dart VM test. Print the TAIL so a damaged decode is
      // visible here instead of surfacing as a drive that dies without an error.
      final g = supplied.geometry;
      final tail = g.length <= 6
          ? g
          : g.sublist(g.length - 6);
      debugPrint('SIM: geometry first ${g.first} last ${g.last} tail '
          '${tail.map((p) => '${p.latitude.toStringAsFixed(5)},'
              '${p.longitude.toStringAsFixed(5)}').join(' | ')}');
      // Refuse a route that decoded into nonsense. Without this the drive dies
      // silently (measured: a destination of 27.917,32.643, then nothing at all
      // — no track, no trip, no error), which looks exactly like a broken app.
      bool inVn(LatLng p) =>
          p.latitude > 7 &&
          p.latitude < 24.5 &&
          p.longitude > 101 &&
          p.longitude < 111;
      if (!inVn(g.first) || !inVn(g.last)) {
        debugPrint('SIM: refusing the supplied route — its endpoints are not in '
            'Việt Nam: ${g.first}, ${g.last} (the polyline decoded wrongly)');
        return;
      }
    }

    // ── 1. the endpoints
    LatLng? from;
    LatLng? to;
    final spec = _simSpec;
    if (supplied != null && supplied.geometry.length >= 2) {
      from = supplied.geometry.first;
      to = supplied.geometry.last;
    } else if (spec.isNotEmpty) {
      final parts =
          spec.split(',').map((s) => double.tryParse(s.trim())).toList();
      final ok = parts.length == 4 &&
          parts.every((p) => p != null) &&
          parts[0]!.abs() <= 90 &&
          parts[1]!.abs() <= 180 &&
          parts[2]!.abs() <= 90 &&
          parts[3]!.abs() <= 180;
      if (!ok) {
        debugPrint('SIM: ?sim= must be lat,lng,lat,lng — got "$spec"');
        return;
      }
      from = LatLng(parts[0]!, parts[1]!);
      to = LatLng(parts[2]!, parts[3]!);
    } else if (_trackSimRef.isNotEmpty) {
      final fixes = await TripReplay.load(_trackSimRef);
      if (!mounted) return;
      if (fixes.isEmpty) {
        debugPrint('SIM: "$_trackSimRef" produced no points to take endpoints '
            'from');
        return;
      }
      from = fixes.first.point;
      to = fixes.last.point;
      debugPrint('SIM: endpoints taken from "$_trackSimRef" '
          '(${fixes.length} points) — the points themselves are NOT driven');
    } else {
      return; // mode not armed
    }

    await _runTrackSim(from, to, supplied: supplied);
  }

  /// ⭐ The simulation itself: a ROUTE in, a TRIP out.
  ///
  /// Two callers, deliberately sharing one body so they cannot drift:
  ///   * the console button ("Mô phỏng GPS") — the app plans the route for the
  ///     waypoints tapped on the map, which is the real driver's path;
  ///   * `?sim=`/`?track=` on a served build, for a headless run.
  ///
  /// Nothing about the roads, limits, signs or announcements is supplied by
  /// either: those come from the map data as the fixes arrive.
  Future<void> _runTrackSim(
    LatLng from,
    LatLng to, {
    OsrmRoute? supplied,
    double? paceMps,
    double? noise,
    int? seed,
    double? feedSpeed,
  }) async {
    // Non-null from here (every branch above either assigns both or returns).
    // Copied into finals because a local captured by a CLOSURE is never
    // promoted to non-null — and `setNavState` below is a closure.
    final LatLng startPoint = from;
    final LatLng endPoint = to;

    final opts = GpsSimOptions(
      // The console's own settings unless the URL overrides them (a headless run
      // passes ?pace=/?tspeed= so it stays reproducible).
      paceMps: paceMps ?? _simParam('pace', simDriveKmh / 3.6),
      noise: noise ?? _simParam('noise', 1.0),
      seed: seed ?? _simParam('seed', 7).round(),
    );
    final driveSpeed = feedSpeed ?? _simParam('tspeed', simFeedSpeed);

    debugPrint(
      'SIM: from ${startPoint.latitude.toStringAsFixed(5)},'
      '${startPoint.longitude.toStringAsFixed(5)} to '
      '${endPoint.latitude.toStringAsFixed(5)},'
      '${endPoint.longitude.toStringAsFixed(5)}; '
      'pace ${(opts.paceMps * 3.6).toStringAsFixed(0)} km/h, '
      'noise ${opts.noise}, seed ${opts.seed}, feed $driveSpeed×',
    );

    // ── 2. the ROUTE — the plan the drive will follow. A supplied one is used
    // as-is; otherwise the app works it out itself, exactly as it does for a
    // driver. Either way the GPS points below are sampled along THIS geometry,
    // which is what keeps them on the route.
    OsrmRoute route;
    if (supplied != null) {
      route = supplied;
    } else {
      try {
        route = await fetchAnyRoute(
          <LatLng>[startPoint, endPoint],
          profile: _routeProfile,
          avoidHighway: _avoidHighway,
          avoidFerry: _avoidFerry,
          preference: _routePreference,
          // ⭐ Generous on purpose. The public OSRM server is the slowest
          // thing in this path and its latency is wild: measured 76 s for a
          // 2.7 km route, against a 20 s budget that then failed the whole run
          // (`TimeoutException`, no route, no trip, and nothing to look at).
          // Waiting longer costs a slow test; timing out costs the test.
          onlineTimeout: const Duration(seconds: 120),
        );
      } catch (e) {
        debugPrint('SIM: could not plan a route from $startPoint to '
            '$endPoint: $e');
        return;
      }
    }
    if (!mounted) return;
    if (route.geometry.length < 2) {
      debugPrint('SIM: the planned route has ${route.geometry.length} points — '
          'nothing to drive');
      return;
    }
    debugPrint(
      'SIM: route planned — ${(route.distance / 1000).toStringAsFixed(2)} km, '
      '${route.steps.length - 1} manoeuvres, ${route.geometry.length} geometry '
      'points',
    );

    // ── 3. the GPS stream: sampled ALONG that geometry, with receiver error
    final track = synthesiseTrack(route.geometry, opts);
    if (track.isEmpty) {
      debugPrint('SIM: the track generator produced no fixes');
      return;
    }
    final span = track.last.at.difference(track.first.at);
    final driven = replayTripMeters(track);
    debugPrint(
      'SIM: ${track.length} synthesised fixes over '
      '${span.inMinutes}m${span.inSeconds % 60}s, '
      '${(driven / 1000).toStringAsFixed(2)} km driven of '
      '${(route.distance / 1000).toStringAsFixed(2)} km planned',
    );

    // ── 4. drive it — through the SAME simulated drive the web console's
    // "Mô phỏng lái xe" button runs (`_startSimulation`), because that path is
    // already the one that walks a PLANNED route and writes a trip. The only
    // difference is the feed: `track:` pushes synthesised fixes through
    // `_onGpsFix` (outlier gate, heading filter, road lookup) instead of
    // stepping the geometry cleanly through `_handleNav`.
    setNavState(() {
      _route = route;
      _alternativeRoutes = [];
      _selectedRoute = 0;
      _planPoints = <LatLng>[startPoint, endPoint];
      _originOverride = startPoint;
      _origin = startPoint;
      _destination = endPoint;
      _current = startPoint;
      _routeBearing = 0;
      _routeStartIndex = 0;
      _navigating = false; // _startSimulation owns the start from here
      _stops
        ..clear()
        ..add(
          TripStop(
            name: 'sim ${endPoint.latitude.toStringAsFixed(4)},'
                '${endPoint.longitude.toStringAsFixed(4)}',
            lat: endPoint.latitude,
            lng: endPoint.longitude,
          ),
        );
      _engine = TurnByTurnEngine(
        route,
        stopNames: _engineStopNames(route),
        maxSpeedMps: _routeProfile.legalMaxMps,
      );
    });
    // The simulation owns the fix stream from here: `_startGps` must NOT also
    // open the real receiver, or two sources would fight over `_onGpsFix` (the
    // same double-feed that made a replay jump, 2026-10-08).
    _trackSimRunning = true;
    simBeginRun(
      label: 'sim ${(route.distance / 1000).toStringAsFixed(1)} km',
      ref: 'sim',
      speed: driveSpeed,
      fixes: track.length,
      meters: route.distance,
      duration: span,
    );
    debugPrint(
      'SIM: driving — ${track.length} GPS points, roads, limits and '
      'announcements come from the map data',
    );
    // What this run does NOT exercise, said out loud: the remote OSRM `/match`
    // road-snapper is skipped (`_maybeSnapToRoad`) because at this feed rate it
    // would issue a call every fraction of a second against a service that took
    // 76 s per call. A trip from this run is a real trip, but it is not a
    // matcher-verified one.
    debugPrint('SIM: scope — remote OSRM /match skipping (online road-snapper '
        'not exercised)');
    await _startSimulation(
      track: track,
      trackSpeed: driveSpeed,
      onFinished: () => unawaited(_finishTrackSim()),
    );
  }

  /// The drive ran out: stop the run and hand back the TRIP.
  Future<void> _finishTrackSim() async {
    _trackSimRunning = false;
    _trackSimSub = null;
    final t = _trip;
    debugPrint('SIM: drive finished — $simFixesFed fixes fed, '
        '${simLog.length} announcements');
    if (t == null) {
      debugPrint('SIM: no trip was recorded');
      simEndRun(SimRunState.done);
      return;
    }
    // The same closing sequence `saveTrip` runs, minus the file write: on the
    // served build there is no documents directory, so this trip's consumer is
    // the driver script, not the disk.
    t.finish();
    try {
      await t.resolvePlaceNames();
    } catch (_) {
      // POI lookup is best-effort; a failure must never lose the trip.
    }
    final body = const JsonEncoder.withIndent('  ').convert(t.toTakeoutJson());
    debugPrint('SIM: TRIP ${t.defaultFileName} — ${body.length} bytes, '
        '${t.fixCount} fixes');
    // ⭐ Hand the OUTPUT to the console. The web build has no documents
    // directory, so the trip is a DOWNLOAD (and a copyable string) rather than a
    // file on disk — the two things that make a simulated drive something the
    // user can keep and audit, without a server in the loop.
    simSetLastTrip(json: body, name: t.defaultFileName);
    if (kIsWeb) {
      final uri = Uri.parse('${Uri.base.origin}/__trip');
      try {
        final res = await http.post(uri, body: body);
        debugPrint('SIM: trip POSTed to $uri -> HTTP ${res.statusCode}');
      } catch (e) {
        debugPrint('SIM: trip POST to $uri failed: $e');
      }
    }
    simEndRun(SimRunState.done);
  }
}
