part of '../navigation_page.dart';

/// The chrome around the map: top search bar, the nav-mode top banner
/// (NavTopBar), and the bottom area (route preview / ETA card + the
/// Google-Maps-style NavStatusBar with live clock, weather and scrub).
extension _NavBars on _NavigationPageState {
  /// "Điểm 2/3" for multi-stop trips ('' for a single destination).
  String _stopLabel(NavProgress? nav) => (nav?.totalStops ?? 0) > 1
      ? 'Điểm ${(nav!.stopIndex + 1)}/${nav.totalStops}'
      : '';

  /// Combined BLE displays status (E-ink clock + ESP32 2.8" nav display):
  /// green when either is connected.
  String get _displaysStatus {
    if (_clockStatus == 'connected' || _mapStatus == 'connected') {
      return 'connected';
    }
    if (_clockStatus == 'connecting' || _mapStatus == 'connecting') {
      return 'connecting';
    }
    return 'off';
  }

  String get _destinationName {
    if (_stops.isNotEmpty) return _stops.last.name;
    final t = _searchCtrl.text.trim();
    return t.isEmpty ? 'Điểm đến' : t;
  }

  Widget _topBar() {
    // NOTE: the mic (voice) + BLE displays buttons both live OUTSIDE this bar
    // now — they float below the search/directions bar on the right (see
    // _buildMainLayout) so the bar is full-width and nothing is glued to it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: _directionsMode
          ? DirectionsBar(
              startController: _startCtrl,
              startFocus: _startFocus,
              endController: _searchCtrl,
              endFocus: _searchFocus,
              onStartChanged: _onStartChanged,
              onEndChanged: _onSearchChanged,
              onSwap: _swapStartEnd,
              onAddStop: _addDirectionsStop,
              onBackToSearch: _enterSearchMode,
              busy: _searching || _building,
              startLabel: _originName.isEmpty ? 'Vị trí hiện tại' : _originName,
            )
          : SearchPill(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
              busy: _searching || _building,
              showClear: _searchCtrl.text.isNotEmpty,
              // Compact "Chỉ đường" toggle inside the bar (Google-Maps style)
              // — keeps the bar full-width.
              onDirections: _toggleDirectionsMode,
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

  /// Compact maneuver bar shown inside the PiP (Picture-in-Picture) window:
  /// big arrow icon + road name + distance • ETA + camera/weather pills.
  /// Fills the bottom edge of the tiny floating window.
  ///
  /// RESPONSIVE: adapts to any PiP shape (the user picks the window aspect in
  /// settings — landscape 16:9, wide 2:1, square, portrait 9:16, tall 1:2).
  /// In a narrow window the pills wrap onto a second row so nothing overlaps;
  /// in a wide window everything sits on one row. Speed + speed-limit live in
  /// the slim top bar ([_pipTopBar]).
  Widget _pipManeuverBar() {
    final nav = _progress;
    final icon = nav == null ? '↑' : iconSymbol(nav.iconCode);
    final road = (nav?.text.isNotEmpty ?? false) ? nav!.text : 'Đang chỉ đường';
    final dist = nav == null ? '' : formatDistance(nav.meter);
    final eta = nav == null ? '' : _etaLabel(nav);
    // Weather a few km AHEAD along the route — emoji + temp pill.
    final ahead = _weatherAhead;
    // Nearest speed/red-light camera ahead (phạt nguội DB) — "📷 400m" chip.
    final cam = _nextCamera;

    // Compact maneuver arrow — kept small so the bar stays thin and the map
    // fills the PiP window.
    final Widget arrow = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kAppBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        icon,
        style: const TextStyle(color: Colors.white, fontSize: 16, height: 1),
      ),
    );

    // Road name + distance/ETA (flexible). The NEXT STEP is the star: the
    // distance to the upcoming maneuver is shown BIG + clear; the current
    // street name is secondary and tiny (it doesn't matter while driving).
    // Small type keeps the bar short so the map stays big.
    final Widget roadCol = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Next step: distance (big, bold, blue) + ETA alongside.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              dist.isEmpty ? 'Đang chỉ đường' : dist,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: kAppBlue,
                height: 1.0,
              ),
            ),
            if (eta.isNotEmpty) ...[
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  eta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5F6368),
                    height: 1.0,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        // Current street — secondary, tiny, truncates.
        Text(
          road,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 8.5,
            color: Color(0xFF5F6368),
            height: 1.0,
          ),
        ),
      ],
    );

    // Camera ahead pill (📷 + metres) — hidden when none nearby.
    final List<Widget> pills = [];
    if (cam != null && cam.routeMeters <= 1500) {
      pills.add(
        Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFFCE8E6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFD93025), width: 1),
          ),
          child: Text(
            '📷 ${cam.routeMeters.round()}m',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFFD93025),
              height: 1.0,
            ),
          ),
        ),
      );
    }
    if (ahead != null) {
      pills.add(
        Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFE8F0FE),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF1A73E8), width: 1),
          ),
          child: Text(
            '${weatherEmoji(ahead.weatherCode)} ${ahead.tempC?.round() ?? '--'}°',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF174EA6),
              height: 1.0,
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.white,
      elevation: 12,
      shadowColor: Colors.black38,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Pills on a separate row below when the window is narrow
            // (portrait / tall shapes) — this is what fixed the overlap.
            final narrow = constraints.maxWidth < 360;
            final row1 = Row(
              children: [
                arrow,
                const SizedBox(width: 8),
                Expanded(child: roadCol),
              ],
            );
            if (narrow && pills.isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    row1,
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        for (var i = 0; i < pills.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          pills[i],
                        ],
                      ],
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                children: [
                  arrow,
                  const SizedBox(width: 8),
                  Expanded(child: roadCol),
                  if (pills.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    for (var i = 0; i < pills.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      pills[i],
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Speed top bar for the PiP window: a SLIM single row (speed + limit) that
  /// owns its space above the map and never overlaps it. Kept short so the
  /// map fills most of the PiP window — the previous version used two big
  /// 46 px circles which ate the height and made the map tiny.
  Widget _pipTopBar() {
    final nav = _progress;
    final limit = _roadInfo?.speedLimit;
    final kmh = (nav?.speedMps.isFinite ?? false)
        ? (nav!.speedMps * 3.6).round()
        : null;
    final speeding = kmh != null && limit != null && kmh > limit;
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black26,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            children: [
              const Icon(Icons.speed, size: 15, color: Color(0xFF5F6368)),
              const SizedBox(width: 5),
              Text(
                kmh == null ? '--' : '$kmh',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  color: speeding ? const Color(0xFFD93025) : kAppBlue,
                ),
              ),
              const SizedBox(width: 3),
              const Text(
                'km/h',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5F6368),
                ),
              ),
              const Spacer(),
              // Speed limit — only when known.
              if (limit != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFD93025),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$limit',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFD93025),
                      height: 1.0,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
    } else if (_pickedPlace != null) {
      // Browse-mode place card: shows the picked place with a "Chỉ đường"
      // button (Google-Maps style search — no route until requested).
      final p = _pickedPlace!;
      card = _PlaceCard(
        name: p.display,
        poi: p.poi,
        onDirections: _directionsToPickedPlace,
        onClose: _clearPickedPlace,
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
        // Google-style bottom info bar: live clock + remaining distance +
        // ETA + weather + trip progress, with the route elevation/terrain
        // strip folded into the SAME card. Full-width at the very bottom
        // edge (the draggable progress line spans the whole width). Default
        // off — toggle from the nav controls (bar-chart button).
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

  /// Toggle speed/red-light camera alerts on/off (persisted).
  void _toggleCameraAlerts() {
    setNavState(() => cameraAlerts = !cameraAlerts);
    if (!cameraAlerts) {
      _nextCamera = null; // hide the PiP camera chip when off
      _lastCameraSig = null;
    } else {
      unawaited(_ensureCameras()); // load the camera index (lazy, not at boot)
      unawaited(_refreshRouteCameras()); // route-nearby layer back on
    }
    loadSettings().then(
      (s) => saveSettings(
        AppSettings(
          forceOffline: s.forceOffline,
          dataSource: s.dataSource,
          vehicleType: s.vehicleType,
          speedOverride: s.speedOverride,
          geocodingProvider: s.geocodingProvider,
          routingEngine: s.routingEngine,
          smoothCamera: s.smoothCamera,
          cameraAlerts: cameraAlerts,
          pipAspect: s.pipAspect,
          ridingMode: s.ridingMode,
          simpleMode: s.simpleMode,
        ),
      ),
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

  /// Toggle the Google-style bottom status bar (clock / distance / ETA).
  void _toggleStatusBar() {
    setNavState(() => _showStatusBar = !_showStatusBar);
  }
}

/// Browse-mode place card (Google-Maps search result): shows the picked
/// place + a "Chỉ đường" (Directions) button. No route is built until the
/// user asks for directions.
class _PlaceCard extends StatelessWidget {
  const _PlaceCard({
    required this.name,
    required this.onDirections,
    required this.onClose,
    this.poi,
  });

  final String name;
  final OfflinePoi? poi;
  final VoidCallback onDirections;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final sub = poi?.subtitle;
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            const Icon(Icons.location_pin, color: Colors.red, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: onDirections,
              icon: const Icon(Icons.directions, size: 18),
              label: const Text('Chỉ đường'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
