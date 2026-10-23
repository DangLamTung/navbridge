part of '../navigation_page.dart';

/// The `build()` UI composition, split out of the State class into an
/// extension so each overlay (PiP, top bar, controls, offline banner, …)
/// lives in its own method and the page shell stays small.
extension _NavBuild on _NavigationPageState {
  /// True on a phone held sideways while navigating. The top banner and ETA
  /// card then float as narrow pills over the map instead of spanning the
  /// full width, so the short landscape screen keeps most of its height.
  bool get _landscapeNav =>
      _navigating && MediaQuery.of(context).orientation == Orientation.landscape;

  /// Top offset for the suggestions / stops / offline-POI overlays. These sit
  /// just BELOW the top bar so they never overlap it. The directions bar is
  /// much taller than the single search pill (2 fields + add-stop row), so in
  /// directions mode the overlay starts lower. Values are LOGICAL pixels:
  /// search pill ends ~y95, directions bar ends ~y195.
  double get _overlayTop {
    // Collapsed directions bar is ~50px tall (one row); expanded ~195.
    if (_directionsMode) return _topBarCollapsed ? 62 : 200;
    return 100;
  }

  /// Picture-in-Picture layout: ONLY the map + a slim maneuver bar — no
  /// search, no controls, no cards. The tiny OS floating window can't fit
  /// the full nav UI.
  Widget _buildPipLayout() {
    // Simple (no-map) mode → compact arrow PiP, not the map.
    if (simpleMode) return _buildPipSimple();
    final route = _route;
    final current = _current;
    return Scaffold(
      backgroundColor: Colors.white,
      // Column (NOT a Stack overlay) so the bars own their space and the map
      // never renders underneath them:
      //   1. speed top bar   — speed + speed limit in a white bar
      //   2. Expanded map    — fills the middle, no overlap with either bar
      //   3. maneuver bar    — bottom edge (arrow + road + distance/ETA)
      body: Column(
        children: [
          _pipTopBar(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: VectorNavMap(
                    // Fresh map per PiP state so the platform view (and zoom)
                    // is recreated — entering PiP uses the PiP zoom, exiting
                    // returns to the full-screen zoom instead of keeping it.
                    key: const ValueKey('navmap-pip'),
                    routeGeometry: route?.geometry ?? const [],
                    routeSteps: route?.steps ?? const [],
                    routeStartIndex: _routeStartIndex,
                    current: current,
                    initialCenter: _initialCenter,
                    speedMps: _progress?.speedMps,
                    gpsAccuracy: _lastGpsAccuracy,
                    bearing: _routeBearing,
                    heading: _heading,
                    headingUp: _headingUp,
                    tilt3D: _tilt3d,
                    terrain3D: _terrain3d,
                    nightMode: _nightMode,
                    vietmapBase:
                        dataSource == 'vietmap' &&
                        !_offline &&
                        VietmapConfig.hasKeys,
                    offline: _offline,
                    // Keep the user's chosen basemap (OSM/CARTO/topo/…) on the nav
                    // map's online fallback — never a surprise style switch.
                    tileSource: _tileSource,
                    carIcon: _carIcon,
                    pois: _pois,
                    selectedPoi: _selectedPoi,
                    searchPois: _searchResults,
                    stops: _stops,
                    // During nav only cameras near the route are loaded (not all
                    // ~1,800 nationwide) — the driver sees what's on their road.
                    cameras: cameraAlerts ? _routeCameras : const [],
                    // …and the PiP window is a postage stamp. The street-level
                    // curve (12 cameras + 20 signs at its z13) covers the road
                    // ahead completely — "too dense to see the path". PiP draws
                    // only the next handful, which the projection already picks
                    // NEAREST THE CAR first (see marker_density.dart).
                    maxCameras: kPipCameraMarkers,
                    maxSignMarkers: kPipSignMarkers,
                    showRadar: radarOn,
                    radarUrl: _radarLayerUrl,
                    showSatellite: _satelliteOn,
                    satelliteUrl: _satelliteLayerUrl,
                    onPoiTap: _onNavPoiTap,
                    onCameraTap: _showCameraInfo,
                    onSignTap: _showSignInfo,
                    signs: _routeSigns,
                    controller: _vmFollow,
                    smoothCamera: smoothCamera,
                    // Same car-arrow screen position as the full-screen map so
                    // entering/leaving PiP doesn't move the arrow.
                    carAnchor: carScreenAnchor,
                    // PiP can't be pinched — start wider than the full-screen
                    // camera so more of the route is visible in the small
                    // window (z13 ≈ ~7 km view).
                    defaultZoom: 13,
                    // No compass in the tiny PiP window — it just eats space.
                    showCompass: false,
                  ),
                ),
                // PiP CANNOT be pinched — two fingers do not fit in the window
                // — so the map gets its own compact +/− instead. Right edge,
                // vertically centred so it clears both the speed bar above and
                // the maneuver bar below.
                Positioned(
                  right: 4,
                  top: 0,
                  bottom: 0,
                  width: 30,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _pipZoomButton(Icons.add, 1),
                        const SizedBox(height: 6),
                        _pipZoomButton(Icons.remove, -1),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _pipManeuverBar(),
        ],
      ),
    );
  }

  /// A compact map-zoom button for the PiP window.
  ///
  /// PiP is too small to pinch, so the zoom is driven through
  /// [VectorNavMapController.zoomBy]. Smaller than the full-screen controls
  /// (30 px, not 46) so a pair of them fits the postage-stamp window without
  /// covering the road.
  Widget _pipZoomButton(IconData icon, double delta) => RoundActionButton(
    icon: icon,
    color: const Color(0xFF1A73E8),
    size: 30,
    onTap: () => _vmFollow.zoomBy(delta),
    child: Icon(icon, color: const Color(0xFF1A73E8), size: 18),
  );

  /// Floating time-scrubber bars for the weather layers — rain radar and the
  /// distinct weather-satellite layer. Each layer that's toggled on and has
  /// frames gets its own slider; nothing renders when all are off/empty.
  Widget _weatherBars() {
    final children = <Widget>[];
    if (radarOn && _radarFrames.isNotEmpty) {
      children.add(
        WeatherTimeBar(
          title: 'Radar',
          icon: Icons.water_drop,
          color: const Color(0xFF1A73E8),
          frames: _radarFrames,
          selected: _radarFrame,
          onSelect: _setRadarFrame,
          loading: _radarLoading,
          onRefresh: _ensureRadar,
          onClose: _toggleRadar,
        ),
      );
    }
    if (_satelliteOn && _satelliteFrames.isNotEmpty) {
      children.add(
        WeatherTimeBar(
          title: 'Vệ tinh',
          icon: Icons.cloud,
          color: const Color(0xFF7B1FA2),
          frames: _satelliteFrames,
          selected: _satelliteFrame,
          onSelect: _setSatelliteFrame,
          loading: _radarLoading,
          onRefresh: _ensureRadar,
          onClose: _toggleSatellite,
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          children[i],
        ],
      ],
    );
  }

  /// Full-page layout (browse + navigation modes): the map layer, the top
  /// bar/banner, the route card, the controls and the overlay chips.
  Widget _buildMainLayout() {
    final route = _route;
    final current = _current;
    return Scaffold(
      body: Stack(
        children: [
          // Navigation mode renders the offline VECTOR map with the
          // Vietmap-navigation-style banner + ETA bar (ui/nav_top_bar.dart +
          // ui/navigation_card.dart). Browsing/search keeps the raster map.
          _navigating && !kIsWeb
              ? VectorNavMap(
                  // Distinct key from the PiP map so leaving PiP builds a fresh
                  // map at the full-screen zoom (z19) rather than inheriting the
                  // PiP zoom.
                  key: const ValueKey('navmap-full'),
                  routeGeometry: route?.geometry ?? const [],
                  routeSteps: route?.steps ?? const [],
                  routeStartIndex: _routeStartIndex,
                  current: current,
                  initialCenter: _initialCenter,
                  speedMps: _progress?.speedMps,
                  gpsAccuracy: _lastGpsAccuracy,
                  bearing: _routeBearing,
                  heading: _heading,
                  headingUp: _headingUp,
                  tilt3D: _tilt3d,
                  terrain3D: _terrain3d,
                  nightMode: _nightMode,
                  // Vietmap light basemap in nav mode when the Vietmap data
                  // source is active, online, and real keys are compiled in.
                  vietmapBase:
                      dataSource == 'vietmap' &&
                      !_offline &&
                      VietmapConfig.hasKeys,
                  offline: _offline,
                  // Keep the user's chosen basemap (OSM/CARTO/topo/…) on the
                  // nav map's online fallback — never a surprise style switch.
                  tileSource: _tileSource,
                  carIcon: _carIcon,
                  pois: _pois,
                  selectedPoi: _selectedPoi,
                  // Search-bar results drawn as blue place markers ahead.
                  searchPois: _searchResults,
                  stops: _stops,
                  // During nav only cameras near the route are loaded (not all
                  // ~1,800 nationwide) — the driver sees what's on their road.
                  cameras: cameraAlerts ? _routeCameras : const [],
                  showRadar: radarOn,
                  radarUrl: _radarLayerUrl,
                  showSatellite: _satelliteOn,
                  satelliteUrl: _satelliteLayerUrl,
                  onPoiTap: _onNavPoiTap,
                  onCameraTap: _showCameraInfo,
                  onSignTap: _showSignInfo,
                  signs: _routeSigns,
                  controller: _vmFollow,
                  smoothCamera: smoothCamera,
                  // Car-arrow screen position (Settings → "Vị trí mũi tên"):
                  // the follow camera looks past the car so the arrow rides
                  // lower on screen and more road stays visible ahead.
                  carAnchor: carScreenAnchor,
                  // No compass on the nav map. In heading-up mode the camera
                  // bearing is essentially never 0, so MapLibre kept the
                  // compass pinned to the top-right corner for the whole drive
                  // — clutter next to the right-hand controls, offering a
                  // re-orient action nobody asked for. Same call as the PiP map.
                  showCompass: false,
                )
              : _buildMap(route, current),
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Pin the top area to the top — the banner and, under it,
                  // the road-info chip flow together so a tall banner (long
                  // destination / expanded step list) can never overlap the
                  // chip.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // While a route is shown the top search bar is hidden
                        // (all info is on the route card below) — the map is
                        // for driving/viewing; search returns after
                        // "Xoá lộ trình".
                        _navigating
                            ? (navBannerBottom
                                  // Moved to the bottom edge — see the bottom
                                  // Positioned below (Settings → "Dẫn đường").
                                  ? const SizedBox.shrink()
                                  : _navTopBar(compact: _landscapeNav))
                            : (_route != null
                                  ? const SizedBox.shrink()
                                  : _topBar()),
                        // Suggestions / stops flow BELOW the bar (same
                        // Column) so they can never overlap it — no hardcoded
                        // offsets that break with font scaling or a collapsed
                        // bar.
                        if (!_navigating)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 66, 0),
                            child: _suggestions.isNotEmpty
                                ? SuggestionList(
                                    suggestions: _suggestions,
                                    onSelected: _selectSuggestion,
                                  )
                                : (_showRecentSearches
                                      // Previous searches — offered as soon as
                                      // the field is focused (Google-Maps
                                      // style), before anything is typed.
                                      ? RecentSearchesList(
                                          items: RecentSearches.instance.items,
                                          onSelected: _selectRecentSearch,
                                          onRemove: _removeRecentSearch,
                                          onClear: _clearRecentSearches,
                                        )
                                      : _stops.isNotEmpty
                                      ? StopsPanel(
                                          stops: _stops,
                                          onMoveUp: (i) => _moveStop(i, -1),
                                          onMoveDown: (i) => _moveStop(i, 1),
                                          onRemove: _removeStop,
                                          onSave: _savePlan,
                                          collapsed: _stopsCollapsed,
                                          onToggleCollapse: () => setNavState(
                                            () => _stopsCollapsed =
                                                !_stopsCollapsed,
                                          ),
                                        )
                                      : const SizedBox.shrink()),
                          ),
                        // One-tap quick places (🏠 Nhà riêng / 💼 Cơ quan) +
                        // the offline POI category chips. These used to be a
                        // separate overlay at a HARDCODED `top: _overlayTop`,
                        // which is why the collapsed directions bar ended up
                        // under them — the offset guessed the bar's height. In
                        // this Column they flow below whatever the bar actually
                        // renders, so no bar shape (collapsed, expanded, long
                        // destination, large font scale) can be covered.
                        if (!_navigating &&
                            _searchCtrl.text.isEmpty &&
                            _suggestions.isEmpty &&
                            _stops.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 66, 0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _quickPlacesRow(),
                                if (_offline) ...[
                                  const SizedBox(height: 6),
                                  _offlinePoiBar(),
                                ],
                              ],
                            ),
                          ),
                        if (_navigating)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 10, 0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // The speed island (speed + limit chip, with the
                                // "sắp tới" sign bar under it) is NOT here any
                                // more: it is a DRAGGABLE overlay of its own —
                                // see [_speedIsland] — so the rider can move it
                                // off the road ahead.
                                // Close chip to dismiss the search / POI
                                // markers on the nav map (blue search markers
                                // + the tapped/selected POI highlight).
                                if (_searchResults.isNotEmpty ||
                                    _selectedPoi != null) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: 'Đóng kết quả tìm kiếm',
                                    child: Material(
                                      color: const Color(0xE6181A22),
                                      borderRadius: BorderRadius.circular(16),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: _clearSearchResults,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.close,
                                                size: 15,
                                                color: Colors.white,
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                'Đóng',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                // Nav controls: a scrollable column capped to
                                // the space ABOVE the bottom bars so it can
                                // NEVER overlap the ETA card / status bar (it
                                // used to run the full height and hid the AI
                                // button behind the bottom chrome).
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight:
                                        MediaQuery.of(context).size.height *
                                        0.5,
                                  ),
                                  child: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // AI assistant — FIRST so it is always
                                        // visible (was last → hidden).
                                        RoundActionButton(
                                          icon: Icons.auto_awesome,
                                          color: const Color(0xFF7B1FA2),
                                          onTap: () => _openAiAssistant(),
                                        ),
                                        const SizedBox(height: 8),
                                        RoundActionButton(
                                          icon: _headingUp
                                              ? Icons.explore
                                              : Icons.navigation,
                                          color: _headingUp
                                              ? kAppBlue
                                              : const Color(0xFF5F6368),
                                          onTap: () => setNavState(
                                            () => _headingUp = !_headingUp,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        // Camera alerts toggle (phạt nguội
                                        // DB) — kept near the TOP so it's
                                        // always visible on the small screen
                                        // (was buried below the scroll fold).
                                        Tooltip(
                                          message: cameraAlerts
                                              ? 'Camera: bật'
                                              : 'Camera: tắt',
                                          child: RoundActionButton(
                                            icon: Icons.videocam,
                                            color: cameraAlerts
                                                ? const Color(0xFFD93025)
                                                : const Color(0xFF5F6368),
                                            onTap: _toggleCameraAlerts,
                                            child: CctvIcon(
                                              size: 22,
                                              color: cameraAlerts
                                                  ? const Color(0xFFD93025)
                                                  : const Color(0xFF5F6368),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        // Map layers: Basemap type + 3D / terrain / radar / satellite overlays
                                        // grouped into ONE comprehensive Google Maps-style picker button.
                                        PopupMenuButton<String>(
                                          tooltip: 'Lớp bản đồ',
                                          position: PopupMenuPosition.under,
                                          offset: const Offset(-160, 8),
                                          color: Colors.white,
                                          elevation: 8,
                                          shadowColor: Colors.black38,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          onSelected: (v) {
                                            if (v.startsWith('type:')) {
                                              _setTileSource(v.substring(5));
                                            } else if (v == '3d') {
                                              setNavState(
                                                () => _tilt3d = !_tilt3d,
                                              );
                                            } else if (v == 'terrain') {
                                              setNavState(
                                                () => _terrain3d = !_terrain3d,
                                              );
                                            } else if (v == 'radar') {
                                              _toggleRadar();
                                            } else if (v == 'satellite') {
                                              _toggleSatellite();
                                            } else if (v == 'night') {
                                              _toggleNight();
                                            }
                                          },
                                          itemBuilder: (context) => [
                                            _layerHeader('Loại bản đồ'),
                                            // First and the default: the map
                                            // works with no signal at all.
                                            _layerItem(
                                              'type:offline',
                                              Icons.cloud_off,
                                              'Ngoại tuyến (đã tải)',
                                              _tileSource == 'offline',
                                            ),
                                            _layerItem(
                                              'type:osm',
                                              Icons.map,
                                              'OpenStreetMap',
                                              _tileSource == 'osm',
                                            ),
                                            _layerItem(
                                              'type:esri-street',
                                              Icons.alt_route,
                                              'ESRI Đường phố',
                                              _tileSource == 'esri-street',
                                            ),
                                            _layerItem(
                                              'type:esri',
                                              Icons.satellite_alt,
                                              'Vệ tinh (ESRI)',
                                              _tileSource == 'esri',
                                            ),
                                            _layerItem(
                                              'type:topo',
                                              Icons.landscape,
                                              'Địa hình (Topo)',
                                              _tileSource == 'topo',
                                            ),
                                            _layerItem(
                                              'type:carto',
                                              Icons.explore,
                                              'CARTO Voyager',
                                              _tileSource == 'carto',
                                            ),
                                            _layerItem(
                                              'type:carto-light',
                                              Icons.light_mode_outlined,
                                              'CARTO Sáng',
                                              _tileSource == 'carto-light',
                                            ),
                                            _layerItem(
                                              'type:carto-dark',
                                              Icons.dark_mode_outlined,
                                              'CARTO Tối',
                                              _tileSource == 'carto-dark',
                                            ),
                                            if (VietmapConfig.hasKeys) ...[
                                              _layerItem(
                                                'type:vietmap',
                                                Icons.navigation,
                                                'VietMap Vector',
                                                _tileSource == 'vietmap',
                                              ),
                                              _layerItem(
                                                'type:vietmapsat',
                                                Icons.satellite,
                                                'VietMap Vệ tinh',
                                                _tileSource == 'vietmapsat',
                                              ),
                                            ],
                                            // Same vector archive, but with the
                                            // online CARTO raster underneath —
                                            // nicer outside the archive's
                                            // coverage while there IS signal.
                                            _layerItem(
                                              'type:vector',
                                              Icons.layers,
                                              'Bản đồ Vector + nền CARTO',
                                              _tileSource == 'vector',
                                            ),
                                            const PopupMenuDivider(height: 12),
                                            _layerHeader('Lớp phủ & Hiệu ứng'),
                                            _layerItem(
                                              '3d',
                                              Icons.threed_rotation,
                                              '3D (nghiêng)',
                                              _tilt3d,
                                            ),
                                            _layerItem(
                                              'terrain',
                                              Icons.terrain,
                                              'Địa hình 3D',
                                              _terrain3d,
                                            ),
                                            _layerItem(
                                              'radar',
                                              Icons.water_drop,
                                              'Radar mưa (RainViewer)',
                                              radarOn,
                                            ),
                                            _layerItem(
                                              'satellite',
                                              Icons.cloud,
                                              'Mây vệ tinh (GIBS)',
                                              _satelliteOn,
                                            ),
                                            _layerItem(
                                              'night',
                                              Icons.nightlight_round,
                                              'Chế độ ban đêm',
                                              _nightMode,
                                            ),
                                          ],
                                          child: Material(
                                            color: Colors.white,
                                            elevation: 4,
                                            shadowColor: Colors.black26,
                                            shape: const CircleBorder(),
                                            child: SizedBox(
                                              width: 46,
                                              height: 46,
                                              child: Icon(
                                                Icons.layers,
                                                color:
                                                    (_tilt3d ||
                                                        _terrain3d ||
                                                        radarOn ||
                                                        _satelliteOn ||
                                                        _nightMode)
                                                    ? kAppBlue
                                                    : const Color(0xFF5F6368),
                                                size: 22,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        RoundActionButton(
                                          icon: _nightMode
                                              ? Icons.dark_mode
                                              : Icons.light_mode,
                                          color: _nightMode
                                              ? kAppBlue
                                              : const Color(0xFF5F6368),
                                          onTap: _toggleNight,
                                        ),
                                        const SizedBox(height: 8),
                                        RoundActionButton(
                                          icon: _showStatusBar
                                              ? Icons.bar_chart
                                              : Icons.bar_chart_outlined,
                                          color: _showStatusBar
                                              ? kAppBlue
                                              : const Color(0xFF5F6368),
                                          onTap: _toggleStatusBar,
                                        ),
                                        const SizedBox(height: 8),
                                        // Picture-in-Picture (Part C): shrink the
                                        // nav into a floating window (Google-Maps
                                        // style). Only shown on capable devices.
                                        RoundActionButton(
                                          icon: Icons.picture_in_picture_alt,
                                          color: const Color(0xFF1A73E8),
                                          onTap: () => _enterPip(),
                                        ),
                                        const SizedBox(height: 8),
                                        RoundActionButton(
                                          icon: _voiceOn
                                              ? Icons.volume_up
                                              : Icons.volume_off,
                                          color: _voiceOn
                                              ? const Color(0xFF34A853)
                                              : const Color(0xFF5F6368),
                                          onTap: () => setNavState(
                                            () => _voiceOn = !_voiceOn,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        _micButton(),
                                        const SizedBox(height: 8),
                                        RoundActionButton(
                                          icon: Icons.directions_car,
                                          color: const Color(0xFF1A73E8),
                                          onTap: _openVietmapNav,
                                        ),
                                        const SizedBox(height: 8),
                                        // "Điều hướng bằng Google Maps" —
                                        // hands off to Google Maps (Google's
                                        // roads + live traffic).
                                        RoundActionButton(
                                          icon: Icons.navigation,
                                          color: const Color(0xFFEA4335),
                                          onTap: _openGoogleMapsNav,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // Weather-layer time scrubbers in NAV mode: sit in
                        // normal flow below the road chip so they can NEVER
                        // overlap the ETA bar or the right-side controls.
                        if (_navigating)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 10, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _weatherBars(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_offline && _showOfflineBanner)
                    Positioned(
                      top: 58,
                      left: 12,
                      right: 12,
                      child: Material(
                        elevation: 4,
                        shadowColor: Colors.black26,
                        borderRadius: BorderRadius.circular(10),
                        color: const Color(0xFF5F6368),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: const [
                              Icon(
                                Icons.cloud_off,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Đang ngoại tuyến — bản đồ & lộ trình đã tải vẫn hoạt động',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_isRerouting)
                    Positioned(
                      top: _navigating ? 150 : 58,
                      left: 12,
                      right: 12,
                      child: Material(
                        elevation: 5,
                        shadowColor: Colors.black38,
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF1A73E8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            children: const [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Đang tính lại lộ trình…',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // Voice/mic banner: shows live "Đang nghe… <text>" while the
                  // recognizer streams partial results, then confirms the
                  // recognized command text for a few seconds. Rendered below
                  // the top bar so it never overlaps the search/controls.
                  if (_voiceBannerVisible)
                    Positioned(
                      top: _navigating ? 150 : 58,
                      left: 12,
                      right: 12,
                      child: Material(
                        elevation: 5,
                        shadowColor: Colors.black38,
                        borderRadius: BorderRadius.circular(12),
                        color: _listening
                            ? const Color(0xFFEA4335)
                            : const Color(0xFF1A73E8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          child: Row(
                            children: [
                              _listening
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _listening
                                      ? (_voiceText.isEmpty
                                            ? 'Đang nghe…'
                                            : 'Đang nghe: “$_voiceText”')
                                      : (_voiceText.isEmpty
                                            ? 'Không nghe rõ, thử lại'
                                            : 'Đã nghe: “$_voiceText”'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  // Voice/mic + BLE displays buttons — floated on the RIGHT,
                  // just BELOW the search/directions bar (they used to sit
                  // inside the top bar and squeezed it → overflow, and the
                  // BLE button looked glued to the bar). Hidden while the
                  // suggestions / stops panel is showing so they never float
                  // on top of it. In nav mode the mic lives in the controls
                  // column instead.
                  if (!_navigating && _suggestions.isEmpty && _stops.isEmpty)
                    Positioned(
                      right: 12,
                      top: _directionsMode ? 200 : 100,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!kIsWeb) ...[
                            DisplaysButton(
                              status: _displaysStatus,
                              onTap: _toggleDisplays,
                            ),
                            const SizedBox(width: 8),
                          ],
                          _micButton(size: 44),
                        ],
                      ),
                    ),
                  // (Quick places + offline POI chips moved INTO the top
                  // Column — see the `_quickPlacesRow()` block above. They were
                  // a hardcoded-offset overlay here, which put them on top of
                  // the collapsed directions bar.)
                  // Weather-layer time scrubbers (browse): rain radar +
                  // weather satellite — drag to watch the storm / clouds move.
                  if (!_navigating)
                    Positioned(
                      left: 12,
                      top: _overlayTop + 116,
                      child: _weatherBars(),
                    ),
                  // Raster-only controls (zoom/locate target the raster map
                  // controller) — hide during vector navigation mode.
                  // Positioned BELOW the floated BLE + voice buttons (which
                  // sit top-right under the search bar) so they don't overlap.
                  if (!_navigating)
                    Positioned(
                      right: 10,
                      top: _directionsMode
                          ? (_topBarCollapsed ? 110 : 252)
                          : 150,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MapControls(
                            onZoomIn: () => _zoomBy(1),
                            onZoomOut: () => _zoomBy(-1),
                            onLocate: _locateMe,
                            hasPosition: current != null,
                          ),
                          const SizedBox(height: 8),
                          // PLANNING MODE entry: directions UI to build a
                          // multi-stop route, export it (GPX/KML/KMZ) and
                          // download the offline map for the area.
                          RoundActionButton(
                            icon: Icons.route,
                            color: const Color(0xFF7B1FA2),
                            onTap: _enterPlanningMode,
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon: Icons.settings,
                            color: kAppBlue,
                            onTap: _openSettings,
                          ),
                          const SizedBox(height: 8),
                          // Speed/red-light camera layer + alerts toggle —
                          // also available while browsing (matches the nav
                          // controls button).
                          Tooltip(
                            message: cameraAlerts
                                ? 'Camera: bật'
                                : 'Camera: tắt',
                            child: RoundActionButton(
                              icon: Icons.videocam,
                              color: cameraAlerts
                                  ? const Color(0xFFD93025)
                                  : const Color(0xFF5F6368),
                              onTap: _toggleCameraAlerts,
                              child: CctvIcon(
                                size: 22,
                                color: cameraAlerts
                                    ? const Color(0xFFD93025)
                                    : const Color(0xFF5F6368),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The turn banner, when the user put it at the BOTTOM
                        // (Settings → "Dẫn đường") — the layout riders know
                        // from Google Maps / Waze. It sits directly above the
                        // ETA bar so the two read as one block.
                        if (_navigating && navBannerBottom)
                          _navTopBar(compact: _landscapeNav),
                        _bottomArea(compact: _landscapeNav),
                      ],
                    ),
                  ),
                  // Auto-center button — rendered in this overlay so it sits
                  // ABOVE the MapLibre platform view (a sibling inside the
                  // map's own Stack is occluded by it). Blue when the user
                  // has panned/zoomed away (follow paused); tapping recenters
                  // the camera on the car and resumes auto-follow. NAV-ONLY:
                  // in browse mode the MapControls locate button already
                  // centers the map — showing this one too made a duplicate
                  // "center" button AND it overlapped the route card's
                  // "Bắt đầu chỉ đường" button (which made taps on Start
                  // silently hit this button instead → "does nothing").
                  // The button is DRAGGABLE — hold and drag it anywhere on
                  // the map (the position is remembered for the session).
                  // The speed island is its own draggable overlay (see
                  // [_speedIsland]) — only while navigating, like this button.
                  if (_navigating) _speedIsland(),
                  if (_navigating) _autoCenterButton(),
                ],
              ),
            ),
          ),
          _simConsoleLayer(),
          // Over the posted limit: a red frame around the whole screen. The
          // chip's red number is easy to miss in peripheral vision while
          // riding; a frame at the screen edge is not. IgnorePointer keeps
          // every control underneath live.
          if (_speedingNow)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFD93025),
                      width: 8,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// True while the car is over the effective posted limit (sign / Waze /
  /// statutory, already vehicle-capped) — drives the red screen frame.
  bool get _speedingNow {
    final nav = _progress;
    if (nav == null || !nav.speedMps.isFinite) return false;
    final limit = _effectiveSpeedLimit;
    return limit > 0 && nav.speedMps * 3.6 > limit;
  }

  Widget _simConsoleLayer() {
    if (!simConsoleEnabled) return const SizedBox.shrink();
    final size = MediaQuery.of(context).size;
    // The console is a debug tool over a map, so it takes the space it needs and
    // no more: it used to be up to 360 x 600, which on a laptop window covered
    // most of the right half of the map ("the right side simulate shit is taking
    // too much space"). It also starts collapsed on the playback route
    // (`nav_sim_panel.dart`) and open on the simulation route, where it is the
    // point of the page.
    final w = (size.width - 24).clamp(200.0, 300.0);
    final h = (size.height - (_navigating ? 280 : 200)).clamp(200.0, 520.0);
    // ⭐ MAX size, not FIXED size. It used to be a fixed box, so "Thu nhỏ"
    // replaced the content with a one-line Row inside a box of the same size —
    // and since the shell is an opaque dark Material, collapsing produced a
    // large BLACK BLOCK that also swallowed every tap on the map underneath
    // (user, 2026-10-09: "thu nhỏ is not thu nhỏ, it is shitty black block, also
    // can not click on map"). A shrink-wrapped child means collapsed really is
    // small, and nothing invisible covers the map.
    return Positioned(
      right: 12,
      top: _navigating ? 96 : 150,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: w, maxHeight: h),
        child: _showSimConsole
            ? SimConsole(
                onClose: () => setNavState(() => _showSimConsole = false),
                onLayerChanged: _onDebugLayerChanged,
              )
            : Align(
                alignment: Alignment.topRight,
                child: Material(
                  elevation: 6,
                  color: const Color(0xF2181A22),
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => setNavState(() => _showSimConsole = true),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bug_report, size: 15, color: Colors.white),
                          SizedBox(width: 5),
                          Text(
                            'Mô phỏng',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// The draggable auto-center ("my_location") button shown while navigating.
  /// Hold and drag to reposition it anywhere on the map; tap to recenter on
  /// the car and resume auto-follow. Blue when follow is paused.
  Widget _autoCenterButton() {
    const button = 46.0; // RoundActionButton-ish size
    final size = MediaQuery.of(context).size;
    // Default: pinned to the LEFT edge, raised above the bottom action bar /
    // route card so it never overlaps them (it's draggable if the driver wants
    // it elsewhere).
    //
    // NOTE: this position is CORRECT as-is (user-confirmed 2026-10-12) — do not
    // "fix" it for the open info bar. The overlap reported against the info bar
    // is a DIFFERENT control and was never reproduced on screen (the tablet was
    // locked at the time); see the session notes before touching this again.
    final pos =
        _centerBtnOffset ??
        (MediaQuery.of(context).orientation == Orientation.landscape
            // Landscape keeps the bottom-left for the floating ETA pill; put
            // the recenter button on the free right edge so it is not pushed
            // off the short screen by the portrait offset (height - 330).
            ? Offset(size.width - button - 14, size.height - button - 14)
            : Offset(14, size.height - 330 - button));
    return Positioned(
      left: pos.dx.clamp(0.0, size.width - button),
      top: pos.dy.clamp(0.0, size.height - button),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Drag anywhere on the map; clamped to the screen so it never slides
        // off. (A plain tap still hits the InkWell → recenter.)
        onPanUpdate: (d) {
          final s = MediaQuery.of(context).size;
          setNavState(() {
            _centerBtnOffset = Offset(
              (pos.dx + d.delta.dx).clamp(0.0, s.width - button),
              (pos.dy + d.delta.dy).clamp(0.0, s.height - button),
            );
          });
        },
        child: ListenableBuilder(
          listenable: _vmFollow,
          builder: (context, child) {
            final following = _vmFollow.following;
            return Material(
              color: following ? Colors.white : const Color(0xFF1A73E8),
              shape: const CircleBorder(),
              elevation: 6,
              shadowColor: Colors.black38,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _vmFollow.recenter,
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Icon(
                    Icons.my_location,
                    color: following ? const Color(0xFF1A73E8) : Colors.white,
                    size: 24,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The speed island — the speed + limit chip with the "sắp tới" sign bar
  /// under it — as a DRAGGABLE overlay on the nav map.
  ///
  /// It used to be pinned under the top bar, where on a small phone it covers
  /// the stretch of road just ahead. Hold and drag it anywhere; the position is
  /// REMEMBERED across sessions (dragged back the same way) — dragging is the
  /// control, there is no menu for it.
  Widget _speedIsland() {
    final size = MediaQuery.of(context).size;
    // Default: under the turn banner on the left, where it has always been.
    final pos = speedIslandX < 0
        ? const Offset(12, 96)
        : Offset(speedIslandX, speedIslandY);
    const margin = 12.0;
    return Positioned(
      left: pos.dx.clamp(0.0, size.width - margin),
      top: pos.dy.clamp(0.0, size.height - margin),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onPanUpdate: (d) {
          final s = MediaQuery.of(context).size;
          setNavState(() {
            speedIslandX = (speedIslandX < 0 ? 12.0 : speedIslandX + d.delta.dx)
                .clamp(0.0, s.width - margin);
            speedIslandY = (speedIslandY < 0 ? 96.0 : speedIslandY + d.delta.dy)
                .clamp(0.0, s.height - margin);
          });
        },
        // Persist once the finger lifts — not per pan update, which would write
        // the settings file dozens of times per drag.
        onPanEnd: (_) => unawaited(saveAllSettings()),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Speed display style (Settings → Hiển thị tốc độ): the compact
            // chip, or the floating widget's round gauge. Same values either
            // way — only the drawing differs.
            if (navSpeedStyle == 'dial')
              SpeedDialChip(
                info: _roadInfo,
                speedMps: _progress?.speedMps,
                limitOverride: _effectiveSpeedLimit > 0
                    ? _effectiveSpeedLimit
                    : null,
                limitSrc: _limitSourceLabel,
                fromEsp: _espActive(),
              )
            else
              RoadInfoChip(
                info: _roadInfo,
                loading: _roadLoading,
                speedMps: _progress?.speedMps,
                limitOverride: _effectiveSpeedLimit > 0
                    ? _effectiveSpeedLimit
                    : null,
                // GPS source tag lives INSIDE the chip so it never overlaps
                // the right-hand controls.
                fromEsp: _espActive(),
              ),
            // The sign bar belongs to the same glance, so it travels with the
            // chip.
            _alertBar(),
          ],
        ),
      ),
    );
  }

  /// A non-selectable category header for the layer menu.
  PopupMenuEntry<String> _layerHeader(String title) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Color(0xFF80868B),
        ),
      ),
    );
  }

  /// A styled layer-menu row (icon + label + active checkmark).
  PopupMenuItem<String> _layerItem(
    String value,
    IconData icon,
    String label,
    bool active,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: active ? kAppBlue : const Color(0xFF5F6368),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? kAppBlue : const Color(0xFF202124),
              ),
            ),
          ),
          if (active) const Icon(Icons.check, size: 16, color: kAppBlue),
        ],
      ),
    );
  }

  /// Fixed arrival moment for the live ETA countdown on the navigation card
  /// (now + remaining duration). The card counts down to it every second.
  DateTime _arrivalTime() {
    final route = _route;
    final nav = _progress;
    if (route == null || route.duration <= 0) return DateTime.now();
    final remain =
        route.duration * (1 - (nav?.progress ?? 0)) * kEtaRealismFactor;
    return DateTime.now().add(Duration(seconds: remain.round()));
  }

  /// Compact elevation/terrain chart for the nav status bar (tap to
  /// expand/collapse). The progress marker follows the live progress, or the
  /// scrubbed preview while the user drags the progress line.
  Widget? _elevationChart(NavProgress? nav) {
    final e = _elevation;
    if (e == null || e.profile.isEmpty) return null;
    final progress = _scrubProgress ?? nav?.progress ?? 0;
    return GestureDetector(
      onTap: () => setNavState(() => _elevationExpanded = !_elevationExpanded),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.terrain, size: 16, color: kAppBlue),
              const SizedBox(width: 6),
              const Text(
                'Độ cao',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Icon(
                _elevationExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: const Color(0xFF5F6368),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ElevationChart(
            profile: e.profile,
            minElev: e.minElev,
            maxElev: e.maxElev,
            up: e.up,
            down: e.down,
            progress: progress,
            compact: !_elevationExpanded,
          ),
        ],
      ),
    );
  }
}
