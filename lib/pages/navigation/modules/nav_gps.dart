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
    // Seed the position quickly: a one-shot network-assisted fix (fast, via
    // the fused provider) so the map centers on the user right away instead
    // of waiting for the stream's first satellite fix — which is slow on the
    // itel and is what made the GPS feel laggy at launch. The 1 Hz stream
    // then takes over.
    unawaited(_seedGpsFix());
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.high,
            // Every fix (no distance filter) → the nav UI, voice and the clock
            // update as fast as the sensor reports, instead of every 3 m.
            distanceFilter: 0,
            // Fix rate: 1000 ms (1 Hz) standard steady rate; the trip log
            // records at the same 1 Hz.
            intervalDuration: const Duration(milliseconds: 1000),
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
  void _onGpsFix(Position p, {bool fromEsp = false}) {
    // Simulated drive drives the route itself — ignore real (stationary) GPS
    // so it can't yank the car back to the phone's location (T9).
    if (_simulating) return;
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
    if (gpsFilter && !_outlierGate.accept(pos, accuracy: p.accuracy, dt: dt)) {
      debugPrint(
        'GPS: REJECTED acc=${p.accuracy}m '
        'dt=${dt == null ? '-' : dt.toStringAsFixed(2)}s',
      );
      return;
    }
    _lastGpsFixTime = fixTime;
    debugPrint(
      'GPS${fromEsp ? '/ESP' : ''}: fix dt=${(dt ?? 0).toStringAsFixed(2)}s '
      'acc=${p.accuracy}m '
      'spd=${p.speed.isNaN ? 0 : p.speed.toStringAsFixed(0)}',
    );
    _current = pos;
    final spd = p.speed.isNaN ? 0.0 : p.speed;
    // Filtered heading: holds while stationary, only applies a big change
    // after two agreeing fixes (see [StrictHeading]).
    _headingFilter.update(p.heading, pos);
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
    return {
      if (nav.text.isNotEmpty) nav.text,
      if (nav.nextText.isNotEmpty) nav.nextText,
      if (nav.nextNextText.isNotEmpty) nav.nextNextText,
    };
  }

  /// The name the publisher would settle on for [candidate] right now.
  ///
  /// Uses the veto only: the hysteresis can DELAY a change, never force one, so
  /// a caller can ask "would this candidate be overruled?" before publishing.
  String _settledName(String candidate) {
    final cur = _roadInfo?.name ?? '';
    final names = _routeNames();
    return pickRoadName(
      current: cur,
      candidate: candidate,
      candidateOnRoute: names.any((n) => sameRoad(n, candidate)),
      currentOnRoute: names.any((n) => sameRoad(n, cur)),
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
  void _publishRoad(RoadInfo next, {LatLng? at}) {
    final cur = _roadInfo;
    if (cur == null) {
      setNavState(() => _roadInfo = next);
      _lastRoadPublishPos = at;
      return;
    }
    final names = _routeNames();
    var name = pickRoadName(
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
        at: DateTime.now(),
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
    setNavState(() => _roadInfo = out);
    _lastRoadPublishPos = at;
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
    try {
      final lim = await speedLimitAt(
        pos,
        headingDeg: _heading == 0 ? null : _heading,
      );
      if (lim == null) return road;
      // Read the layer kind / street name immediately after the lookup — the
      // next lookup overwrites both.
      final layerKind = lastLimitLayer();
      final layerName = lastWazeStreetName();
      // A named segment may only supply the limit of the road it names: if the
      // veto would keep a different road on screen, that segment is a crossing
      // street and its value belongs to that other road.
      if (!postedLimitMatchesName(layerName, _settledName(layerName ?? road.name))) {
        return road;
      }
      return applyPostedLayer(
        road,
        kmh: lim,
        vehicle: vehicleType,
        layerSrc: layerKind ?? srcSegment,
        name: layerName,
        inTown: await _townAt(pos),
      );
    } catch (_) {
      return road; // no layer data → the class default stands
    }
  }

  /// Is the car in a built-up area (khu đông dân cư)? Needed by the vehicle
  /// ceiling on a layer value, and [RoadInfo.urban] cannot answer it: that flag
  /// is false whenever the way carries an OSM `maxspeed` tag, even in a city.
  /// Cached per 150 m — the probe is a 25-cell lookup over the bundled POI grid.
  Future<bool> _townAt(LatLng pos) async {
    final prev = _inTownPos;
    if (prev != null && distanceMeters(prev, pos) < 150) return _inTown;
    _inTownPos = pos;
    _inTown = await builtUpRuleApplies(pos, hasPosted: false);
    return _inTown;
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
  /// True while [_correctSpeedFromWaze] is in flight (declared on the state
  /// class — see [_wazeCorrecting]): keeps the limit and the street name from
  /// the SAME segment lookup.
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
    if (_wazeCorrecting) return; // keep limit + street from the same lookup
    _wazeCorrecting = true;
    try {
      await _correctSpeedFromWazeInner(raw, snapped: snapped);
    } finally {
      _wazeCorrecting = false;
    }
  }

  Future<void> _correctSpeedFromWazeInner(LatLng pos, {LatLng? snapped}) async {
    var lim = await speedLimitAt(
      pos,
      headingDeg: _heading == 0 ? null : _heading,
    );
    var usedSnapped = false;
    if (lim == null && snapped != null && snapped != pos) {
      lim = await speedLimitAt(
        snapped,
        headingDeg: _heading == 0 ? null : _heading,
      );
      usedSnapped = lim != null;
    }
    // Which layer answered — read before any other lookup overwrites it.
    final layerKind = lastLimitLayer();
    // Street name from the SAME segment record that produced the limit. Must be
    // read immediately after speedLimitAt — the next lookup overwrites it.
    final wazeName = lastWazeStreetName();
    if (!mounted) return;
    final cur = _roadInfo;
    if (cur == null) return;
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
    final limitUsable = postedLimitMatchesName(wazeName, _settledName(name));
    if (lim == null || !limitUsable) {
      if (lim != null) {
        debugPrint('ROAD: dropped layer limit $lim from "$wazeName" — the road '
            'on screen is "${_settledName(name)}"');
      }
      // No posted limit for THIS road: still adopt a better name when the layer
      // has one, so the label can catch up independently of the limit — but
      // only through the route veto + hysteresis (a segment the car is not on
      // must not rename the road; see lib/core/road_match.dart).
      if (name == cur.name) return;
      debugPrint('ROAD: waze street "$name" (was "${cur.name}")');
      _publishRoad(cur.copyWith(name: name));
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
    _publishRoad(next);
  }

  /// Xe mô tô is PROHIBITED on đường cao tốc (VN road law). The route planner
  /// still lets a motorbike ride the car network (OSRM has no motorbike
  /// profile), so when the current road is a motorway the driver must be told
  /// they can't be there. Warn once per entry; re-arm once back on a normal
  /// road.
  void _maybeWarnMotorwayProhibited() {
    if (!_voiceOn || !_voice.ready) return;
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
    // GraphHopper sends Infinity for `maxspeed=none` — treat any non-finite
    // value as "no tagged limit" and fall back to the statutory class default.
    // Also reject implausible finite readings: a mis-decoded max_speed edge
    // once turned a real 50 km/h limit into a bogus "31" (and vice versa).
    // A sane posted limit is 5..200 km/h; anything outside is data noise.
    final msRaw = g['maxspeed'];
    final ms = (msRaw is num && msRaw.isFinite && msRaw >= 5 && msRaw <= 200)
        ? msRaw.toInt()
        : null;
    // Vehicle-aware statutory fallback. The graph's max_speed is a CAR tag,
    // so for motorbikes / trucks it only tightens the statutory class default
    // — a motorbike never inherits the car's posted limit.
    //
    // `oneway` comes from the graph (the OSM import stores it); `lanes` is not
    // in GraphHopper's default encodings, so it stays null and
    // [urbanLimit] then treats a one-way street as ≥2 làn (a one-way through
    // street), which is what the VN built-up rule keys on.
    final oneway = parseOneway(g['oneway'] as String?);
    final lanes = parseLanes(g['lanes']);
    final divided = g['divided'] == true;
    // The graph rarely carries a real `maxspeed`, so its value is the class
    // default — which is the RURAL one (primary 80 for a car / 60 for a mô tô).
    // Inside a town that is wrong: the built-up rule caps it at 50 (60 on a
    // đường đôi). POI density decides which table applies; a posted value
    // (graph maxspeed or a Waze segment) always wins over it.
    final urban = await builtUpRuleApplies(pos, hasPosted: (ms ?? 0) > 0);
    // Shared constructor, so this path and the Overpass path cannot drift apart
    // (see [roadInfoFromRoad]).
    return roadInfoFromRoad(
      name: (g['name'] ?? '') as String,
      highway: highway,
      vehicle: vehicleType,
      taggedKmh: ms ?? 0,
      maxspeedTag: ms == null ? null : '$ms',
      oneway: oneway,
      lanes: lanes,
      divided: divided,
      urban: urban,
    );
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
    );
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
