part of '../navigation_page.dart';

/// The `build()` UI composition, split out of the State class into an
/// extension so each overlay (PiP, top bar, controls, offline banner, …)
/// lives in its own method and the page shell stays small.
extension _NavBuild on _NavigationPageState {
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
                    showRadar: radarOn,
                    radarUrl: _radarLayerUrl,
                    showSatellite: _satelliteOn,
                    satelliteUrl: _satelliteLayerUrl,
                    onPoiTap: _onNavPoiTap,
                    onCameraTap: _showCameraInfo,
                    signs: _routeSigns,
                    controller: _vmFollow,
                    smoothCamera: smoothCamera,
                    // PiP can't be pinched — start a bit wider so more of the
                    // route is visible in the small window (z14 ≈ ~5 km view).
                    defaultZoom: 14,
                    // No compass in the tiny PiP window — it just eats space.
                    showCompass: false,
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
          _navigating
              ? VectorNavMap(
                  // Distinct key from the PiP map so leaving PiP builds a fresh
                  // map at the full-screen zoom (z19) rather than inheriting the
                  // PiP zoom.
                  key: const ValueKey('navmap-full'),
                  routeGeometry: route?.geometry ?? const [],
                  routeSteps: route?.steps ?? const [],
                  routeStartIndex: _routeStartIndex,
                  current: current,
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
                  signs: _routeSigns,
                  controller: _vmFollow,
                  smoothCamera: smoothCamera,
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
                            ? _navTopBar()
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
                                : (_stops.isNotEmpty
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
                        if (_navigating)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 10, 0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                RoadInfoChip(
                                  info: _roadInfo,
                                  loading: _roadLoading,
                                  speedMps: _progress?.speedMps,
                                  limitOverride: _effectiveSpeedLimit > 0
                                      ? _effectiveSpeedLimit
                                      : null,
                                  // GPS source tag lives INSIDE the chip so it
                                  // never overlaps the right controls column.
                                  fromEsp: _espActive(),
                                ),
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
                                        // Rain-radar overlay toggle
                                        // (RainViewer, free) — live rain map
                                        // over the basemap while driving.
                                        Tooltip(
                                          message: radarOn
                                              ? 'Radar: bật'
                                              : 'Radar: tắt',
                                          child: RoundActionButton(
                                            icon: Icons.water_drop,
                                            color: radarOn
                                                ? const Color(0xFF1A73E8)
                                                : const Color(0xFF5F6368),
                                            onTap: _toggleRadar,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        // Weather-satellite overlay toggle
                                        // (RainViewer infrared clouds) — a
                                        // distinct layer from the radar.
                                        Tooltip(
                                          message: _satelliteOn
                                              ? 'Vệ tinh thời tiết: bật'
                                              : 'Vệ tinh thời tiết: tắt',
                                          child: RoundActionButton(
                                            icon: Icons.cloud,
                                            color: _satelliteOn
                                                ? const Color(0xFF7B1FA2)
                                                : const Color(0xFF5F6368),
                                            onTap: _toggleSatellite,
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
                                        // Basemap layer cycle (online OSM /
                                        // CARTO / topo / ESRI / Vietmap).
                                        RoundActionButton(
                                          icon: Icons.map_outlined,
                                          color: const Color(0xFF1A73E8),
                                          onTap: _cycleTileSource,
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
                                        RoundActionButton(
                                          icon: Icons.emoji_emotions_outlined,
                                          color: const Color(0xFFF4B400),
                                          onTap: _cycleCarIcon,
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
                                          icon: Icons.local_gas_station,
                                          color: const Color(0xFFF4B400),
                                          onTap: _findNearestGas,
                                        ),
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
                          DisplaysButton(
                            status: _displaysStatus,
                            onTap: _toggleDisplays,
                          ),
                          const SizedBox(width: 8),
                          _micButton(size: 44),
                        ],
                      ),
                    ),
                  // One-tap quick places (🏠 Nhà riêng / 💼 Cơ quan) RIGHT
                  // below the search bar, with the offline POI category chips
                  // stacked under them — one column, so nothing overlaps.
                  // Shown while browsing with an EMPTY search box. Chips are
                  // draggable to reorder.
                  if (!_navigating &&
                      _searchCtrl.text.isEmpty &&
                      _suggestions.isEmpty &&
                      _stops.isEmpty)
                    Positioned(
                      left: 12,
                      right: 66,
                      top: _overlayTop,
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
                          const SizedBox(height: 8),
                          // Rain-radar overlay toggle (RainViewer, free).
                          Tooltip(
                            message: radarOn ? 'Radar: bật' : 'Radar: tắt',
                            child: RoundActionButton(
                              icon: Icons.water_drop,
                              color: radarOn
                                  ? const Color(0xFF1A73E8)
                                  : const Color(0xFF5F6368),
                              onTap: _toggleRadar,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Weather-satellite overlay toggle (RainViewer
                          // infrared clouds) — distinct from the radar.
                          Tooltip(
                            message: _satelliteOn
                                ? 'Vệ tinh thời tiết: bật'
                                : 'Vệ tinh thời tiết: tắt',
                            child: RoundActionButton(
                              icon: Icons.cloud,
                              color: _satelliteOn
                                  ? const Color(0xFF7B1FA2)
                                  : const Color(0xFF5F6368),
                              onTap: _toggleSatellite,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _bottomArea(),
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
                  if (_navigating) _autoCenterButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The draggable auto-center ("my_location") button shown while navigating.
  /// Hold and drag to reposition it anywhere on the map; tap to recenter on
  /// the car and resume auto-follow. Blue when follow is paused.
  Widget _autoCenterButton() {
    const button = 46.0; // RoundActionButton-ish size
    final size = MediaQuery.of(context).size;
    // Default: bottom-right (was right:14 / bottom:230).
    final pos =
        _centerBtnOffset ??
        Offset(size.width - 14 - button, size.height - 230 - button);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
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
