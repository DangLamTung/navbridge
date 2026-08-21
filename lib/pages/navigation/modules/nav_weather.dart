part of '../navigation_page.dart';

/// Weather for the bottom status bar (Open-Meteo, refreshed every 10 min on a
/// background async call so it never blocks the UI).
extension _NavWeather on _NavigationPageState {
  /// Start refreshing the current weather (Open-Meteo) for the bottom status
  /// bar while navigating; refreshed every 10 minutes. Also refreshes the
  /// "weather ahead" (sampled along the route) for the PiP window. The fetch
  /// runs on a background (async) call so it never blocks the UI.
  void _startWeather() {
    _stopWeather();
    _rainAheadSpoken = false; // re-arm the rain-ahead warning each trip
    _refreshWeather();
    _refreshWeatherAhead();
    _weatherTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _refreshWeather();
      _refreshWeatherAhead();
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
    final w = await fetchWeather(
      cur.latitude,
      cur.longitude,
    ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    if (mounted && w != null) setNavState(() => _weather = w);
  }

  Future<void> _refreshWeather() async {
    final cur = _current ?? _origin;
    if (cur == null) return;
    final w = await fetchWeather(cur.latitude, cur.longitude);
    if (mounted && w != null) setNavState(() => _weather = w);
    if (w != null) await _sendMapWeather(); // push to the ESP banner
  }

  /// Weather a few km AHEAD along the route (for the PiP window, so you can
  /// see what's coming while driving). Samples the route polyline at ~1.5 km
  /// / 3 km / 4.5 km ahead, fetches current conditions at each, and merges
  /// them via [mergeWeatherAhead] (worst weather code wins, temp averaged).
  Future<void> _refreshWeatherAhead() async {
    final geometry = _route?.geometry;
    if (geometry == null || geometry.length < 2) return;
    final points = <LatLng>[];
    // Walk the polyline, collecting a point roughly every 1.5 km, up to ~4.5
    // km ahead of the current position.
    const dist = Distance();
    var ahead = 0.0;
    for (var i = 1; i < geometry.length && points.length < 4; i++) {
      final a = geometry[i - 1];
      final b = geometry[i];
      final seg = dist.as(LengthUnit.Meter, a, b);
      ahead += seg;
      if (ahead >= 1500) {
        points.add(b);
        ahead = 0.0; // restart the window from this sample point
      }
    }
    if (points.isEmpty) return;
    final results = await Future.wait(
      points.map((p) => fetchWeather(p.latitude, p.longitude)),
    );
    final merged = mergeWeatherAhead(results.whereType<WeatherInfo>());
    if (mounted && merged != null) {
      setNavState(() => _weatherAhead = merged);
      _announceRainAhead(merged);
    }
  }

  /// Speak a ONE-TIME warning when rain is present or likely on the route
  /// AHEAD (from the Open-Meteo samples a few km down the road). Deduped per
  /// nav session so it doesn't nag the driver.
  void _announceRainAhead(WeatherInfo ahead) {
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
    final phrase = raining
        ? 'Trời đang mưa trên tuyến đường phía trước.'
        : 'Trời sắp mưa trên tuyến đường phía trước, xác suất $p phần trăm.';
    _voice.speak(phrase);
  }

  /// Check the nearest speed/red-light camera AHEAD on the route and warn the
  /// driver once per camera: voice + background notification. `_nextCamera`
  /// feeds the PiP camera chip (updated every nav fix, cheap — straight-line
  /// reject then a 1.5 km along-route window).
  void _checkCameraAhead(LatLng snapped, List<LatLng> geometry) {
    if (!cameraAlerts) {
      debugPrint('CAMERA: SKIPPED (cameraAlerts=$cameraAlerts)');
      return;
    }
    // Throttle the projection work to ~1 Hz.
    final now = DateTime.now();
    if (_lastCameraCheck != null &&
        now.difference(_lastCameraCheck!) < const Duration(seconds: 1)) {
      return;
    }
    _lastCameraCheck = now;
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
    // Only the PiP chip / voice alert uses this — the MAP camera layer is
    // route-wide (see `_refreshRouteCameras`), not car-centric, so it stays
    // visible for the whole trip instead of being empty most of the time.
    setNavState(() {
      _nextCamera = next;
    });

    // Warn once per camera when it's near (<= ~600 m ahead). Deduped so the
    // driver isn't nagged repeatedly while approaching the same camera.
    if (next != null && next.routeMeters <= 600 && sig != _lastCameraSig) {
      _lastCameraSig = sig;
      final m = next.routeMeters.round();
      final phrase = switch (next.camera.focus) {
        'speed' => 'Camera tốc độ phía trước $m mét',
        'red_light' => 'Camera đèn đỏ phía trước $m mét',
        _ => 'Camera phía trước $m mét',
      };
      _voice.speak(phrase);
      unawaited(NavForegroundService.instance.notifyCamera(next.camera, m));
      debugPrint('CAMERA: $phrase — ${next.camera.name}');
    }
  }
}
