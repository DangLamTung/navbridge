part of '../navigation_page.dart';

/// Weather for the bottom status bar (Open-Meteo, refreshed every 10 min on a
/// background async call so it never blocks the UI).
extension _NavWeather on _NavigationPageState {
  /// Start refreshing the current weather (Open-Meteo) for the bottom status
  /// bar while navigating; refreshed every 3 minutes (was 10 — the driver
  /// wants to KNOW when rain is closing in, not 10 minutes late). Also
  /// refreshes the "weather ahead" (sampled along the route) for the PiP
  /// window + the rain-ahead voice warning, and keeps the live rain-radar
  /// fresh when it's toggled on. The fetch runs on a background (async) call
  /// so it never blocks the UI.
  void _startWeather() {
    _stopWeather();
    _rainAheadSpoken = false; // re-arm the rain-ahead warning each trip
    _refreshWeather();
    _refreshWeatherAhead();
    _weatherTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      _refreshWeather();
      _refreshWeatherAhead();
      // Radar "realtime": keep the frame index fresh so the driver sees
      // approaching rain as it happens.
      if (radarOn) unawaited(_ensureRadar());
    });
  }

  void _stopWeather() {
    _weatherTimer?.cancel();
    _weatherTimer = null;
  }

  /// Make sure the AI has CURRENT weather: fetch it now if we've never
  /// fetched (e.g. the AI chat was opened BEFORE a route started, so
  /// [_startWeather] never ran). Returns fast when weather is already known
  /// or there is no location yet (then the AI just can't know — no position).
  Future<void> _ensureWeather() async {
    if (_weather != null) return;
    final cur = _current ?? _origin;
    if (cur == null) return;
    final w = await fetchBestWeather(
      cur.latitude,
      cur.longitude,
    ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    if (mounted && w != null) setNavState(() => _weather = w);
  }

  Future<void> _refreshWeather() async {
    final cur = _current ?? _origin;
    if (cur == null) return;
    // Real METAR station data (nearest VN airport) merged with Open-Meteo.
    final w = await fetchBestWeather(cur.latitude, cur.longitude);
    if (mounted && w != null) setNavState(() => _weather = w);
    if (w != null) await _sendMapWeather(); // push to the ESP banner
  }

  /// Weather a few km AHEAD along the route (for the PiP window, so you can
  /// see what's coming while driving). Samples the route polyline at ~1.5 km
  /// / 3 km / 4.5 km ahead, fetches current conditions at each, and merges
  /// them via [mergeWeatherAhead] (worst weather code wins, temp averaged).
  /// Also remembers the DISTANCE of the nearest raining sample so the voice
  /// can say WHERE on the route it's raining ("tell the place raining on
  /// route").
  Future<void> _refreshWeatherAhead() async {
    final geometry = _route?.geometry;
    if (geometry == null || geometry.length < 2) return;
    final samples = <(LatLng, int)>[];
    // Walk the polyline, collecting a point roughly every 1.5 km, up to ~4.5
    // km ahead of the current position (with its distance in metres).
    const dist = Distance();
    var ahead = 0.0;
    for (var i = 1; i < geometry.length && samples.length < 4; i++) {
      final a = geometry[i - 1];
      final b = geometry[i];
      final seg = dist.as(LengthUnit.Meter, a, b);
      ahead += seg;
      if (ahead >= 1500) {
        samples.add((b, ahead.round()));
        ahead = 0.0; // restart the window from this sample point
      }
    }
    if (samples.isEmpty) return;
    final results = await Future.wait(
      samples.map((p) => fetchWeather(p.$1.latitude, p.$1.longitude)),
    );
    final paired = <(WeatherInfo, int)>[];
    for (var i = 0; i < results.length; i++) {
      final w = results[i];
      if (w != null) paired.add((w, samples[i].$2));
    }
    final merged = mergeWeatherAhead(paired.map((p) => p.$1));
    if (mounted && merged != null) {
      setNavState(() => _weatherAhead = merged);
      // Nearest sample that is actually raining (worst weather first).
      int? rainMeters;
      for (final (w, m) in paired) {
        final code = w.weatherCode;
        if (code != null &&
            ((code >= 51 && code <= 67) ||
                (code >= 80 && code <= 86) ||
                code >= 95)) {
          rainMeters = m;
          break;
        }
      }
      if (rainMeters == null) {
        for (final (w, m) in paired) {
          if ((w.rainProbSoon ?? 0) >= 60) {
            rainMeters = m;
            break;
          }
        }
      }
      _announceRainAhead(merged, rainMeters);
      // Re-arm once the ahead-weather clears, so rain appearing later (a new
      // cell moving in) gets announced again instead of being one-shot per
      // trip — "realtime rain ahead" the driver asked for.
      final code = merged.weatherCode;
      final raining =
          code != null &&
          ((code >= 51 && code <= 67) ||
              (code >= 80 && code <= 86) ||
              code >= 95);
      final p = merged.rainProbSoon;
      if (!raining && (p == null || p < 60)) {
        _rainAheadSpoken = false;
      }
    }
  }

  /// Speak a ONE-TIME warning when rain is present or likely on the route
  /// AHEAD (from the Open-Meteo samples a few km down the road), including
  /// how far ahead it is. Deduped per nav session so it doesn't nag.
  void _announceRainAhead(WeatherInfo ahead, int? rainMeters) {
    if (!_voiceOn || _rainAheadSpoken) return;
    final code = ahead.weatherCode;
    final raining =
        code != null &&
        ((code >= 51 && code <= 67) ||
            (code >= 80 && code <= 86) ||
            code >= 95);
    final p = ahead.rainProbSoon;
    if (!raining && (p == null || p < 60)) return;
    _rainAheadSpoken = true;
    final kmStr = rainMeters != null && rainMeters > 0
        ? (rainMeters / 1000).clamp(0.1, 99).toStringAsFixed(1)
        : null;
    final phrase = raining
        ? (kmStr != null
              ? 'Trời đang mưa phía trước, cách đây khoảng $kmStr ki lô mét.'
              : 'Trời đang mưa trên tuyến đường phía trước.')
        : 'Trời sắp mưa trên tuyến đường phía trước, xác suất $p phần trăm.';
    _voice.speak(phrase);
  }

  /// Check the nearest speed/red-light camera AHEAD on the route and warn the
  /// driver once per camera: voice + background notification. `_nextCamera`
  /// feeds the PiP camera chip (updated every nav fix, cheap — straight-line
  /// reject then a 1.5 km along-route window).
  void _checkCameraAhead(LatLng snapped, List<LatLng> geometry) {
    // The VOICE warning follows `cameraVoice` (default ON); the on-map camera
    // icons + PiP chip follow `cameraAlerts`. The user wants the voice even
    // when the map camera display is switched off.
    if (!cameraAlerts && !cameraVoice) {
      debugPrint(
        'CAMERA: SKIPPED (cameraAlerts=$cameraAlerts voice=$cameraVoice)',
      );
      return;
    }
    // Throttle the projection work to ~1 Hz.
    if (!_cameraGate.tryOpen()) return;
    if (geometry.length < 2) {
      debugPrint('CAMERA: SKIPPED (geometry ${geometry.length})');
      return;
    }
    // Fire-and-forget: the projection is a small local computation, run async
    // so a huge camera list never blocks the nav loop.
    unawaited(_cameraAheadAsync(snapped, geometry));
  }

  Future<void> _cameraAheadAsync(LatLng snapped, List<LatLng> geometry) async {
    final ahead = await camerasAheadOnRoute(
      snapped,
      geometry,
      maxAheadMeters: 1500,
    );
    debugPrint(
      'CAMERA: ahead=${ahead.length} '
      'next=${ahead.isEmpty ? 0 : ahead.first.routeMeters.toStringAsFixed(0)}m',
    );
    if (!mounted) return;
    final next = ahead.isEmpty ? null : ahead.first;
    final sig = next == null ? '' : '${next.camera.lat},${next.camera.lng}';
    // PiP chip / AI camera context — only when the on-map camera display is
    // on; the MAP camera layer is route-wide (`_refreshRouteCameras`).
    setNavState(() {
      _nextCamera = cameraAlerts ? next : null;
    });

    // VOICE — gated by `cameraVoice` (default ON) so the warning works even
    // with the on-map camera display off. Warn TWICE per camera: once far
    // (~600 m ahead) and once near (~100 m) as the final reminder — never
    // nagged repeatedly in between. The PiP chip (_nextCamera) still updates
    // every fix; only the VOICE is zoned.
    if (cameraVoice && next != null && next.routeMeters <= 600) {
      final m = next.routeMeters.round();
      final near = next.routeMeters <= 100;
      final zsig = '$sig/${near ? 'near' : 'far'}';
      if (!_cameraDedupe.seen(zsig)) {
        final phrase = switch (next.camera.focus) {
          'speed' =>
            near
                ? 'Camera tốc độ ngay phía trước'
                : 'Camera tốc độ phía trước ${formatDistanceSpoken(next.routeMeters)}',
          'red_light' =>
            near
                ? 'Camera đèn đỏ ngay phía trước'
                : 'Camera đèn đỏ phía trước ${formatDistanceSpoken(next.routeMeters)}',
          'violations' =>
            near
                ? 'Khu vực giám sát ngay phía trước'
                : 'Khu vực giám sát phía trước ${formatDistanceSpoken(next.routeMeters)}',
          _ =>
            near
                ? 'Camera ngay phía trước'
                : 'Camera phía trước ${formatDistanceSpoken(next.routeMeters)}',
        };
        _voice.speak(phrase);
        unawaited(NavForegroundService.instance.notifyCamera(next.camera, m));
        debugPrint('CAMERA: $phrase — ${next.camera.name}');
      }
    }
  }
}
