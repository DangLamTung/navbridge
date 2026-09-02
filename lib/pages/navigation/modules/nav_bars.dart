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
    if (_clockStatus == 'connecting' ||
        _mapStatus == 'connecting' ||
        _autoConnect.isConnecting) {
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
          ? (_topBarCollapsed
                ? CollapsedDirectionsBar(
                    destination: _destinationName,
                    startLabel: _originName.isEmpty
                        ? 'Vị trí hiện tại'
                        : _originName,
                    onExpand: () => setNavState(() => _topBarCollapsed = false),
                    onBackToSearch: _enterSearchMode,
                  )
                : DirectionsBar(
                    startController: _startCtrl,
                    startFocus: _startFocus,
                    endController: _searchCtrl,
                    endFocus: _searchFocus,
                    onStartChanged: _onStartChanged,
                    onEndChanged: _onSearchChanged,
                    onSwap: _swapStartEnd,
                    onAddStop: _addDirectionsStop,
                    onBackToSearch: _enterSearchMode,
                    onCollapse: () =>
                        setNavState(() => _topBarCollapsed = true),
                    busy: _searching || _building,
                    startLabel: _originName.isEmpty
                        ? 'Vị trí hiện tại'
                        : _originName,
                  ))
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
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kAppBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        icon,
        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1),
      ),
    );

    // Road name + distance/ETA (flexible). The CURRENT ROAD is the star now
    // (user: "make the road part bigger") — bold + readable; the distance to
    // the upcoming maneuver is the smaller secondary line. Compact type keeps
    // the bar short so the map stays big.
    final Widget roadCol = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Rolls left↔right (marquee) when the window is too narrow to show the
        // whole road name, instead of cutting it off with "…". Shows full text
        // statically when there's room.
        MarqueeText(
          road,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF202124),
            height: 1.05,
          ),
        ),
        const SizedBox(height: 1),
        // Next step: distance (bold blue) + ETA alongside — smaller.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              dist.isEmpty ? 'Đang chỉ đường' : dist,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
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
      ],
    );

    // Camera ahead pill (📷 + metres) — hidden when none nearby.
    final List<Widget> pills = [];
    if (cam != null && cam.routeMeters <= 1500) {
      pills.add(
        Container(
          height: 20,
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
              fontSize: 9,
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
          height: 20,
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
              fontSize: 9,
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
    final limit = _effectiveSpeedLimit;
    final kmh = (nav?.speedMps.isFinite ?? false)
        ? (nav!.speedMps * 3.6).round()
        : null;
    final speeding = kmh != null && limit > 0 && kmh > limit;
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
              if (limit > 0)
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
      card = _routeCardCollapsed
          ? _collapsedRouteCard(route)
          : RoutePreviewCard(
              etaText:
                  '${((route.duration * kEtaRealismFactor) / 60).round()} ph',
              distanceText: formatDistance(route.distance),
              destination: _destinationName,
              stopCount: _stops.length,
              profile: _routeProfile,
              onProfile: _setRouteProfile,
              onStart: _startNavigation,
              onClear: _exitNavigation,
              onSimulate: _startSimulation,
              onExportGpx: _exportRouteGpx,
              onExportKml: _exportRouteKmlKmz,
              onDownloadMap: _downloadRouteMap,
              tollCost: route.tollCost,
              alternativeLabels: [
                for (final r in _alternativeRoutes)
                  '${((r.duration * kEtaRealismFactor) / 60).round()} ph • ${formatDistance(r.distance)}',
              ],
              selectedAlternative: _selectedRoute,
              onAlternative: _selectAlternative,
              avoidHighway: _avoidHighway,
              onToggleAvoidHighway: _toggleAvoidHighway,
              avoidFerry: _avoidFerry,
              onToggleAvoidFerry: _toggleAvoidFerry,
              preference: _routePreference,
              onPreference: _setRoutePreference,
              onSaveRoute: _saveFavoriteRoute,
              optionsExpanded: !_routeOptionsCollapsed,
              onToggleOptions: () => setNavState(
                () => _routeOptionsCollapsed = !_routeOptionsCollapsed,
              ),
              onCollapseAll: () =>
                  setNavState(() => _routeCardCollapsed = true),
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

  /// Compact collapsed route card (the "Bắt đầu chỉ đường" card minimised to
  /// one row): destination + ETA • distance + a quick "Đi" (start) button +
  /// an expand chevron. Default state — keeps the bottom-right clear.
  Widget _collapsedRouteCard(OsrmRoute route) {
    return Material(
      elevation: 10,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setNavState(() => _routeCardCollapsed = false),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.flag, color: kAppBlue, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _destinationName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${((route.duration * kEtaRealismFactor) / 60).round()} '
                      'ph • ${formatDistance(route.distance)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAppBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _startNavigation,
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text(
                    'Đi',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Mở rộng lộ trình',
                icon: Icon(Icons.expand_more, color: Colors.grey[700]),
                onPressed: () => setNavState(() => _routeCardCollapsed = false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Toggle speed/red-light camera alerts on/off (persisted).
  void _toggleCameraAlerts() {
    setNavState(() => cameraAlerts = !cameraAlerts);
    if (!cameraAlerts) {
      _nextCamera = null; // hide the PiP camera chip when off
      _cameraDedupe.reset();
    } else {
      unawaited(_ensureCameras()); // load the camera index (lazy, not at boot)
      unawaited(_refreshRouteCameras()); // route-nearby layer back on
    }
    loadSettings().then(
      (s) =>
          saveSettings(s.copyWith(cameraAlerts: cameraAlerts, radar: radarOn)),
    );
  }

  int _etaMinutes() {
    final route = _route;
    final nav = _progress;
    if (route == null || route.duration <= 0) return 0;
    final remain =
        route.duration * (1 - (nav?.progress ?? 0)) * kEtaRealismFactor;
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
