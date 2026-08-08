part of 'navigation_page.dart';

/// The chrome around the map: top search bar, the nav-mode top banner
/// (NavTopBar), and the bottom area (route preview / ETA card + the
/// Google-Maps-style NavStatusBar with live clock, weather and scrub).
extension _NavBars on _NavigationPageState {
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
          DisplaysButton(status: _displaysStatus, onTap: _toggleDisplays),
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

  void _toggleStatusBar() {
    setNavState(() => _showStatusBar = !_showStatusBar);
  }
}
