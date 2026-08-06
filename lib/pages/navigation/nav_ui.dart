part of 'navigation_page.dart';

extension _NavUi on _NavigationPageState {

  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  /// Vietmap-style "overview" button: fit the camera to the whole route
  /// (leaving room for the top banner and the bottom ETA bar).
  void _overviewRoute() {
    final r = _route;
    if (r == null || r.geometry.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(r.geometry);
    _map.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(50, 170, 50, 240),
      ),
    );
  }

  void _cycleCarIcon() {
    final i = kCarIcons.indexOf(_carIcon);
    setNavState(() => _carIcon = kCarIcons[(i + 1) % kCarIcons.length]);
  }

  String _stopLabel(NavProgress? nav) => (nav?.totalStops ?? 0) > 1
      ? 'Điểm ${(nav!.stopIndex + 1)}/${nav.totalStops}'
      : '';

  // ---- Vietmap's own navigation SDK ------------------------------------

  /// Long-press the map to insert a via point and re-plan (interactive
  /// route editing on the OSM/offline map).
  void _addViaPoint(LatLng pos) {
    final stops = List<TripStop>.of(_stops);
    if (stops.isNotEmpty) {
      stops.insert(
        stops.length - 1,
        TripStop(name: 'Điểm giữa', lat: pos.latitude, lng: pos.longitude),
      );
    }
    setNavState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();
  }

  double _distToLine(LatLng p, List<LatLng> poly) {
    if (poly.isEmpty) return double.infinity;
    var best = distanceMeters(p, poly.first);
    for (var i = 1; i < poly.length; i++) {
      final d = distanceMeters(p, poly[i]);
      if (d < best) best = d;
    }
    return best;
  }

  void _updateDragHandles(OsrmRoute? route) {
    _dragHandles = [];
    final g = route?.geometry ?? const <LatLng>[];
    if (route == null || g.length < 2 || _stops.isEmpty) return;
    final cum = route.stopCumulative;
    for (var j = 0; j < _stops.length; j++) {
      final cStart = j == 0 ? 0.0 : (j - 1 < cum.length ? cum[j - 1] : 0);
      final cEnd = j < cum.length ? cum[j] : route.distance;
      final dist = route.distance <= 0 ? 1.0 : route.distance;
      final frac = ((cStart + cEnd) / 2) / dist;
      final idx = (frac * (g.length - 1)).round().clamp(0, g.length - 1);
      _dragHandles.add(g[idx]);
    }
  }

  void _commitDragHandle(int segIndex) {
    if (segIndex < 0 || segIndex >= _dragHandles.length) return;
    final via = _dragHandles[segIndex];
    final stops = List<TripStop>.of(_stops);
    final idx = segIndex.clamp(0, stops.length);
    stops.insert(
      idx,
      TripStop(name: 'Điểm giữa', lat: via.latitude, lng: via.longitude),
    );
    setNavState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();
  }

  Future<void> _loadElevation(OsrmRoute route) async {
    final key = '${route.distance.round()}:${route.geometry.length}';
    final cached = _elevationCache[key];
    if (cached != null) {
      if (mounted) setNavState(() => _elevation = cached);
      return;
    }
    final e = await fetchRouteElevation(route.geometry);
    if (e != null) _elevationCache[key] = e;
    debugPrint(
      'ELEV: route ${route.distance.round()}m → '
      '${e == null ? 'no data' : 'up=${e.up.round()} down=${e.down.round()} pts=${e.profile.length}'}',
    );
    if (mounted) setNavState(() => _elevation = e);
  }

  void _toggleAvoidHighway() {
    setNavState(() => _avoidHighway = !_avoidHighway);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }

  void _toggleAvoidFerry() {
    setNavState(() => _avoidFerry = !_avoidFerry);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }

  void _toggleNight() {
    setNavState(() => _nightMode = !_nightMode);
  }

  void _toggleStatusBar() {
    setNavState(() => _showStatusBar = !_showStatusBar);
  }

  void _cycleTileLayer() {
    final i = _NavigationPageState._tileLayerNames.indexOf(_tileSource);
    final next = _NavigationPageState._tileLayerNames[(i + 1) % _NavigationPageState._tileLayerNames.length];
    setNavState(() {
      _tileSource = next;
      _tileProvider = OfflineTileProvider(source: next);
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Bản đồ: $_tileSource'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
  void _locateMe() {
    final c = _current;
    if (c != null) _map.move(c, 17);
  }

  String get _destinationName {
    if (_stops.isNotEmpty) return _stops.last.name;
    final t = _searchCtrl.text.trim();
    return t.isEmpty ? 'Điểm đến' : t;
  }
  Future<void> _openTrips() async {
    final plan = await Navigator.of(
      context,
    ).push<TripPlan>(MaterialPageRoute(builder: (_) => const TripsScreen()));
    if (plan != null && mounted) {
      setNavState(() {
        _stops
          ..clear()
          ..addAll(plan.stops);
        _destination = plan.stops.isEmpty ? null : plan.stops.last.pos;
      });
      _buildPlanRoute();
    }
  }
  Future<void> _openOffline() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const OfflineScreen()));
    // The user may have changed the data source — reload it.
    if (!mounted) return;
    final s = await loadSettings();
    dataSource = s.dataSource;
    setNavState(() {});
  }

  Widget _buildMap(OsrmRoute? route, LatLng? current) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: current ?? const LatLng(10.8231, 106.6297),
            initialZoom: 13,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            // Keep the route drag handle glued to its point while panning.
            onPositionChanged: (cam, _) => _camNotifier.value = cam,
            // Google-style interactive route editing on the preview map:
            // tap an alternative route line to select it, long-press to add
            // a via point and re-plan.
            onTap: (_, tapPos) {
              if (_navigating || _alternativeRoutes.length <= 1) return;
              for (var i = 0; i < _alternativeRoutes.length; i++) {
                if (i == _selectedRoute) continue;
                if (_distToLine(tapPos, _alternativeRoutes[i].geometry) <
                    0.05 /* ~50m */ ) {
                  _selectAlternative(i);
                  return;
                }
              }
            },
            onLongPress: (_, pos) {
              if (!_navigating) {
                _addViaPoint(pos);
              }
            },
          ),
          children: [
            TileLayer(
              // Basemap layer (changeable): OSM / CARTO / OpenTopoMap / ESRI
              // satellite. Requests are throttled to the OSM tile policy and
              // auto-fail over; each layer caches under its own folder so
              // styles never mix.
              urlTemplate: _NavigationPageState._tileLayers[_tileSource],
              userAgentPackageName: 'com.navbridge.app',
              tileProvider: _tileProvider,
            ),
            if (route != null)
              PolylineLayer(
                polylines: [
                  // Alternative routes drawn dimmed (Google's tap-to-compare).
                  for (var i = 0; i < _alternativeRoutes.length; i++)
                    if (i != _selectedRoute)
                      Polyline(
                        points: _alternativeRoutes[i].geometry,
                        color: const Color(0xFF9BB2E8),
                        strokeWidth: 5,
                      ),
                  // white casing under the blue route (Google look)
                  Polyline(
                    points: route.geometry,
                    color: Colors.white,
                    strokeWidth: 9,
                  ),
                  Polyline(
                    points: route.geometry,
                    color: kAppBlue,
                    strokeWidth: 6,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (_origin != null)
                  Marker(
                    point: _origin!,
                    width: 30,
                    height: 30,
                    child: const OriginMarker(),
                  ),
                // numbered markers for intermediate stops (the last stop is
                // the red destination pin below)
                for (var i = 0; i < _stops.length - 1; i++)
                  Marker(
                    point: _stops[i].pos,
                    width: 28,
                    height: 28,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: kAppBlue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (_destination != null)
                  Marker(
                    point: _destination!,
                    width: 44,
                    height: 44,
                    child: const Icon(
                      Icons.location_pin,
                      color: Colors.red,
                      size: 44,
                      shadows: [Shadow(color: Colors.black38, blurRadius: 4)],
                    ),
                  ),
                if (current != null)
                  Marker(
                    point: current,
                    width: 26,
                    height: 26,
                    child: const CurrentMarker(),
                  ),
                // POI quick-search highlights.
                for (final p in _pois)
                  Marker(
                    point: p.pos,
                    width: 26,
                    height: 26,
                    child: Container(
                      decoration: BoxDecoration(
                        color: poiColor(p.type),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                      child: Icon(p.type.icon, size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ],
        ),
        // Google-style draggable route handles (preview mode only): one per
        // segment — a simple route has exactly one.
        if (!_navigating && route != null && _dragHandles.isNotEmpty)
          for (var i = 0; i < _dragHandles.length; i++)
            _RouteDragHandle(
              key: ValueKey('drag$i'),
              via: _dragHandles[i],
              cameraListenable: _camNotifier,
              onDrag: (delta) {
                final cam = _map.camera;
                final cur = cam.latLngToScreenPoint(_dragHandles[i]);
                final next = cam.pointToLatLng(
                  Point(cur.x + delta.dx, cur.y + delta.dy),
                );
                setNavState(() => _dragHandles[i] = next);
              },
              onDragEnd: () => _commitDragHandle(i),
            ),
      ],
    );
  }
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: SearchPill(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
              busy: _searching || _building,
              showClear: _searchCtrl.text.isNotEmpty,
            ),
          ),
          const SizedBox(width: 8),
          RoundActionButton(
            icon: _listening ? Icons.mic : Icons.mic_none,
            color: _listening ? const Color(0xFFEA4335) : kAppBlue,
            onTap: _toggleListening,
            size: 44,
          ),
          const SizedBox(width: 8),
          ClockButton(status: _clockStatus, onTap: _toggleClock),
          const SizedBox(width: 8),
          RoundActionButton(
            icon: Icons.history,
            color: kAppBlue,
            onTap: _openTrips,
            size: 44,
          ),
        ],
      ),
    );
  }

  Widget _navTopBar() {
    final nav = _progress;
    return NavTopBar(
      destination: _destinationName,
      progress: nav,
      recording: _trip != null,
      clockConnected: _clock.isConnected,
      stopLabel: _stopLabel(nav),
      steps: _route?.steps ?? const [],
      expanded: _showSteps,
      onToggle: () => setNavState(() => _showSteps = !_showSteps),
      onExit: _exitNavigation,
    );
  }
  Widget _bottomArea() {
    final route = _route;
    final nav = _progress;
    final stopLabel = _stopLabel(nav);
    final Widget? card;
    if (_navigating) {
      // Google-style arrival card when the destination is reached, otherwise
      // the Vietmap-style ETA bar (ui/navigation_card.dart).
      if (nav != null && nav.iconCode == iconArrive) {
        card = ArrivalCard(
          progress: nav,
          onStop: _exitNavigation,
          stopLabel: stopLabel,
        );
      } else {
        card = NavigationCard(
          progress: _progress,
          onStop: _exitNavigation,
          onOverview: _overviewRoute,
          stopLabel: stopLabel,
          arrivalTime: _arrivalTime(),
        );
      }
    } else if (route != null) {
      card = RoutePreviewCard(
        etaText: '${(route.duration / 60).round()} ph',
        distanceText: formatDistance(route.distance),
        destination: _destinationName,
        stopCount: _stops.length,
        profile: _routeProfile,
        onProfile: _setRouteProfile,
        onStart: _startNavigation,
        onClear: _exitNavigation,
        tollCost: route.tollCost,
        alternativeLabels: [
          for (final r in _alternativeRoutes)
            '${(r.duration / 60).round()} ph • ${formatDistance(r.distance)}',
        ],
        selectedAlternative: _selectedRoute,
        onAlternative: _selectAlternative,
        avoidHighway: _avoidHighway,
        onToggleAvoidHighway: _toggleAvoidHighway,
        avoidFerry: _avoidFerry,
        onToggleAvoidFerry: _toggleAvoidFerry,
        elevation: _elevation,
      );
    } else {
      card = null;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_navigating) _poiArea(),
        const OsmAttribution(),
        if (card != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: card,
          ),
        // Google-Maps-style bottom bar: live clock + remaining distance +
        // ETA + weather + trip progress, with the route elevation/terrain
        // strip folded into the SAME card — toggleable from the nav controls
        // (bar button). The progress line is draggable to scrub the path.
        if (_navigating && _showStatusBar)
          NavStatusBar(
            remainingMeters: (nav?.meter ?? route?.distance ?? 0).toDouble(),
            etaMinutes: _etaMinutes(),
            progress: nav?.progress ?? 0,
            weather: _weather,
            elevation: _elevationChart(nav),
            onScrub: _onScrubProgress,
            onScrubEnd: _clearScrub,
            previewProgress: _scrubProgress,
            mode: _barMode,
            onModeChanged: (m) => setNavState(() => _barMode = m),
            destination: _destinationName,
          ),
      ],
    );
  }

  int _etaMinutes() {
    final route = _route;
    final nav = _progress;
    if (route == null || route.duration <= 0) return 0;
    final remain = route.duration * (1 - (nav?.progress ?? 0));
    return (remain / 60).round().clamp(0, 9999);
  }

  void _onScrubProgress(double p) => setNavState(() => _scrubProgress = p);

  void _clearScrub() => setNavState(() => _scrubProgress = null);

  /// Start refreshing the current weather (Open-Meteo) for the bottom status
  /// bar while navigating; refreshed every 10 minutes. The fetch runs on a
  /// background (async) call so it never blocks the UI.
  void _startWeather() {
    _stopWeather();
    _refreshWeather();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _refreshWeather(),
    );
  }
  void _stopWeather() {
    _weatherTimer?.cancel();
    _weatherTimer = null;
  }
  Future<void> _refreshWeather() async {
    final cur = _current ?? _origin;
    if (cur == null) return;
    final w = await fetchWeather(cur.latitude, cur.longitude);
    if (mounted && w != null) setNavState(() => _weather = w);
  }
}
