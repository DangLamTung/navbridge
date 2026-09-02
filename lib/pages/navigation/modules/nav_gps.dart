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
      // Assume they might grant it; the lifecycle observer will restart GPS
      // when they return to the app if they do. Returning false here would
      // instantly flash the error snackbar while they're leaving the app.
      return true;
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
    // Off-route detection lives in [_handleNav] (authoritative). Here we add
    // Google-style NETWORK matching (offline graph): fast road-based reroute
    // that fires when the nearest ROAD isn't part of the route — works even
    // on parallel roads where the raw >50 m distance check can't tell.
    unawaited(_networkMatch(pos));
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

  /// Google-style NETWORK matching (offline graph): snap the fix to the
  /// nearest ROAD, then check whether that road is part of the route.
  /// - Snapped point IS on the route (<20 m) → clear both latches (a fix
  ///   that reads 40 m off line but snaps to a route road is FINE — this
  ///   kills the false reroutes that raw-distance checks cause near parallel
  ///   streets and lane offsets).
  /// - Snapped point is on a DIFFERENT road → genuine deviation → latch and
  ///   reroute after ~3 s (road-based, so it works even on parallel roads).
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
    _netOnRoute = onRoute; // authoritative while fresh (see _handleNav)
    if (onRoute) {
      _netOffSince = null;
      _offRouteSince = null; // network says we're on a route road — trust it
      return;
    }
    // On a road that is NOT part of the route → real deviation.
    _netOffSince ??= now;
    if (now.difference(_netOffSince!) >= const Duration(seconds: 3)) {
      _netOffSince = null;
      _reRoute(pos, speedMps: _lastSpeedMps);
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
          // VN rarely tags maxspeed, so the graph limit is usually only the
          // statutory default. When ONLINE, correct it in the background from
          // OSM's REAL `maxspeed` tag — the graph value shows instantly and
          // the correction overwrites it ~1 s later (never blocks the UI).
          if (r.maxspeed == null && !_offline && !forceOffline) {
            unawaited(_correctSpeedFromOsm(pos));
          }
          // Offline, nationwide, instant: the bundled DATMAP layer carries the
          // REAL posted limit on 93k road segments — overwrite the statutory
          // estimate whenever a segment is right under the car.
          unawaited(_correctSpeedFromDatmap(pos));
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
      final r = await fetchRoadInfo(pos, vehicle: vehicleType);
      if (!mounted) return;
      setNavState(() => _roadInfo = r);
      _maybeWarnMotorwayProhibited();
    } catch (_) {
      // keep the last known road on failure
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
    // Apply the real posted DATMAP limit here too — the graph branch already
    // calls _correctSpeedFromDatmap, but this Overpass fallback path skipped
    // it, so the announced limit could be the statutory estimate instead of
    // the real per-segment value. (After the finally so the _roadLoading
    // guard inside the helper passes.)
    unawaited(_correctSpeedFromDatmap(pos));
  }

  /// Background speed-limit correction: re-fetch road info from OSM (which
  /// reads the real `maxspeed` tag when tagged) and overwrite the limit the
  /// offline graph only estimated via the statutory class default. Best-effort
  /// — on failure the graph/statutory value is kept.
  Future<void> _correctSpeedFromOsm(LatLng pos) async {
    if (_roadLoading) return; // don't stack with the main fetch
    setNavState(() => _roadLoading = true);
    try {
      final r = await fetchRoadInfo(pos, vehicle: vehicleType);
      if (mounted && r != null) setNavState(() => _roadInfo = r);
    } catch (_) {
      // keep the current (graph/statutory) value
    } finally {
      if (mounted) setNavState(() => _roadLoading = false);
    }
  }

  /// Real posted speed-limit correction from the bundled DATMAP layer
  /// (offline, nationwide, instant — no network). The on-device graph can only
  /// estimate the statutory class default; DATMAP carries the actual posted
  /// limit on 93k road segments, so when one is within a few metres of the car
  /// its value wins. Best-effort: on no match the graph/statutory value stands.
  Future<void> _correctSpeedFromDatmap(LatLng pos) async {
    if (_roadLoading) return; // don't stack/race with the main road fetch
    final lim = await speedLimitAt(pos);
    if (lim == null || !mounted) return;
    final cur = _roadInfo;
    if (cur == null) return;
    // The DATMAP limit is a posted (car) value; for motorbikes/trucks it only
    // TIGHTENS the vehicle's statutory class default (never lifts it), same as
    // the OSM maxspeed handling.
    final v = effectiveLimit(cur.highway, vehicle: vehicleType, taggedKmh: lim);
    if (v == cur.speedLimit) return;
    debugPrint(
      'ROAD: datmap limit=$lim -> $v (was ${cur.speedLimit}) ${cur.highway}',
    );
    setNavState(() {
      _roadInfo = RoadInfo(
        name: cur.name,
        highway: cur.highway,
        maxspeed: '$v',
        label: cur.label,
        speedLimit: v,
      );
    });
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
    // Vehicle-aware statutory fallback. The graph's max_speed is a CAR tag,
    // so for motorbikes / trucks it only tightens the statutory class default
    // — a motorbike never inherits the car's posted limit.
    final limit = effectiveLimit(
      highway,
      vehicle: vehicleType,
      taggedKmh: ms ?? 0,
    );
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
    t.addFix(pos, speedMps: speedMps, heading: _heading);
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
