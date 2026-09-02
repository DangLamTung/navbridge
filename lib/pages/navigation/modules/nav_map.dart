part of '../navigation_page.dart';

/// Map rendering + camera + basemap layers for the browse (raster FlutterMap)
/// page. The nav-mode vector map lives in `ui/vector_nav_map.dart`; this only
/// owns the raster preview map + its controls (zoom / overview / locate /
/// layer cycle / night + car icon).
extension _NavMap on _NavigationPageState {
  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  /// Decimated route geometry for the browse map, cached per route object so
  /// a long-distance route is reduced ONCE — not re-decimated on every 1 Hz
  /// rebuild (that iteration itself was part of the routing-stage freeze).
  List<LatLng> _displayGeometry(List<LatLng> geo) {
    if (_routeDisplayCache.length > 8) _routeDisplayCache.clear();
    return _routeDisplayCache.putIfAbsent(geo, () => decimatePolyline(geo));
  }

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

  /// Cycle the car marker icon (arrow → fun emojis).
  void _cycleCarIcon() {
    final i = kCarIcons.indexOf(_carIcon);
    setNavState(() => _carIcon = kCarIcons[(i + 1) % kCarIcons.length]);
  }

  /// Marker color for a camera's focus: speed = red, red-light = amber,
  /// general enforcement = blue (matches the nav-map layer in
  /// `ui/vector_nav_map.dart`).
  Color _cameraFocusColor(String focus) => switch (focus) {
    'speed' => const Color(0xFFD93025),
    'red_light' => const Color(0xFFF9AB00),
    _ => const Color(0xFF4285F4),
  };

  /// Camera data-source color for the corner dot (waze=purple, police=teal,
  /// osm=green, vietmap=indigo, ?=grey) — matches the nav-map source ring.
  Color _cameraSourceColor(String source) => switch (source) {
    'waze' => const Color(0xFF7B1FA2),
    'police' => const Color(0xFF00897B),
    'osm' => const Color(0xFF34A853),
    'vietmap' => const Color(0xFF5C6BC0),
    _ => const Color(0xFF5F6368),
  };

  /// Bottom-sheet details for a camera marker tapped on the map: what kind of
  /// camera it is + which source reported it (CSGT / Waze / Vietmap / OSM) so
  /// the driver can judge how much to trust it. Also used by the nav map's
  /// camera tap.
  void _showCameraInfo(OfflineCamera c) {
    final type = switch (c.type) {
      'speed_camera' =>
        (c.speedLimit ?? 0) > 0
            ? 'Camera tốc độ ${c.speedLimit} km/h'
            : 'Camera tốc độ',
      'traffic_camera' => 'Camera giám sát giao thông',
      'penalty_camera' => 'Camera phạt nguội',
      'red_light' => 'Camera đèn đỏ',
      _ => switch (c.focus) {
        'speed' => 'Camera tốc độ',
        'red_light' => 'Camera đèn đỏ',
        'violations' => 'Camera phạt nguội',
        'sign' => 'Biển báo',
        _ => 'Camera',
      },
    };
    final seg = c.segmentMeters;
    final detail = <String>[
      if (seg != null && seg > 0) 'Đoạn giám sát ~${formatDistanceSpoken(seg)}',
      if (c.devices != null && c.devices! > 0) '${c.devices} thiết bị',
      if (c.district != null && c.district!.isNotEmpty) c.district!,
    ].join(' · ');
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _cameraFocusColor(c.focus),
                      shape: BoxShape.circle,
                    ),
                    child: const CctvIcon(size: 12),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      type,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (c.name.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  c.name,
                  style: TextStyle(fontSize: 13, color: Colors.grey[800]),
                ),
              ],
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _cameraSourceColor(c.source),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Nguồn: ${cameraSourceLabel(c.source)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _locateMe() {
    final c = _current;
    if (c != null) _map.move(c, 17);
  }

  /// Toggle night (dark) map mode.
  void _toggleNight() {
    setNavState(() => _nightMode = !_nightMode);
  }

  Widget _buildMap(OsrmRoute? route, LatLng? current) {
    // Browse map with camera alerts on: load the camera index LAZILY (after
    // the first build) so cold start stays fast but cameras still appear.
    if (cameraAlerts && !_camerasRequested) {
      _camerasRequested = true;
      unawaited(_ensureCameras());
    }
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: current ?? const LatLng(10.8231, 106.6297),
            initialZoom: 13,
            // Map-tinted background (warm land tone, not stark white) so a
            // zoomed-out / offline area with no tiles doesn't look like a
            // blank white screen.
            backgroundColor: const Color(0xFFF1EEE6),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
            // Keep the floating widget's auto-hide in sync with the browse
            // map zoom EVEN without GPS fixes (deduped + cheap).
            onPositionChanged: (pos, hasGesture) => _syncOverlayVisibility(),
            // Google-style interactive route editing on the preview map:
            // tap an alternative route line to select it, long-press to add
            // a via point and re-plan.
            onTap: (_, tapPos) {
              // Directions mode: a plain tap sets the ACTIVE field — the
              // start point (green) or the destination (red), Google-Maps
              // style. Tapping the route/alternative lines still selects
              // them when present.
              if (_directionsMode && !_navigating) {
                if (_navField == _NavField.start) {
                  setNavState(() {
                    _originOverride = tapPos;
                    _originName = 'Điểm trên bản đồ';
                    _startCtrl.text = _originName;
                    _suggestions = [];
                  });
                } else {
                  _planToPoint(
                    'Điểm trên bản đồ',
                    tapPos.latitude,
                    tapPos.longitude,
                  );
                }
                return;
              }
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
            // Rain radar (RainViewer) — a translucent live rain map above the
            // basemap, below the route. Online-only (fresh data every frame).
            // High-res 512px tiles (RainViewer serves 512 = 2x the 256 default)
            // so the overlay stays crisp when zoomed in — we request 512 tiles
            // and render them at their native size (no simulated-retina blur).
            if (radarOn && _radarLayerUrl != null)
              Opacity(
                opacity: 0.55,
                child: TileLayer(
                  urlTemplate: _radarLayerUrl!,
                  userAgentPackageName: 'com.navbridge.app',
                  tileProvider: NetworkTileProvider(),
                  tileSize: 512,
                  maxNativeZoom: 7,
                ),
              ),
            // Weather satellite (clouds) — a DISTINCT translucent layer from
            // the radar, own time scrubber. GIBS tiles exist only up to z6.
            if (_satelliteOn && _satelliteLayerUrl != null)
              Opacity(
                opacity: 0.55,
                child: TileLayer(
                  urlTemplate: _satelliteLayerUrl!,
                  userAgentPackageName: 'com.navbridge.app',
                  tileProvider: NetworkTileProvider(),
                  tileSize: 512,
                  maxNativeZoom: 6,
                ),
              ),
            if (route != null)
              PolylineLayer(
                polylines: [
                  // Alternative routes drawn dimmed (Google's tap-to-compare).
                  // Display-geometry is DECIMATED so a long-distance route
                  // doesn't paint tens of thousands of vertices (the freeze).
                  for (var i = 0; i < _alternativeRoutes.length; i++)
                    if (i != _selectedRoute)
                      Polyline(
                        points: _displayGeometry(
                          _alternativeRoutes[i].geometry,
                        ),
                        color: const Color(0xFF9BB2E8),
                        strokeWidth: 5,
                      ),
                  // white casing under the blue route (Google look)
                  Polyline(
                    points: _displayGeometry(route.geometry),
                    color: Colors.white,
                    strokeWidth: 9,
                  ),
                  Polyline(
                    points: _displayGeometry(route.geometry),
                    color: kAppBlue,
                    strokeWidth: 6,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                // Browse-mode picked place → a red pin (Google Maps search).
                if (_pickedPlace != null)
                  Marker(
                    point: LatLng(_pickedPlace!.lat, _pickedPlace!.lng),
                    width: 44,
                    height: 44,
                    child: const Icon(
                      Icons.location_pin,
                      color: Colors.red,
                      size: 44,
                      shadows: [Shadow(color: Colors.black38, blurRadius: 4)],
                    ),
                  ),
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
                // Camera layer: colored dot per focus (speed / red-light /
                // general), shown when camera alerts are on. A single circle
                // (no separate 📷 text) so it fits the 26×26 marker box — the
                // old dot+tag Column overflowed by 5 px for every camera. A
                // tiny corner dot marks the data source (waze/police/osm).
                // Only NEAR-THE-USER cameras ([_nearCameras], ≤120) are drawn
                // — all ~70k nationwide markers crushed the low-end phone.
                if (cameraAlerts)
                  for (final c in _nearCameras)
                    Marker(
                      point: c.pos,
                      width: 26,
                      height: 26,
                      // Tap a camera marker → details (type + source) so the
                      // driver knows what it is and how much to trust it.
                      child: GestureDetector(
                        onTap: () => _showCameraInfo(c),
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: _cameraFocusColor(c.focus),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: const CctvIcon(size: 11),
                            ),
                            // Source tag dot (waze=purple · police=teal ·
                            // osm=green · vietmap=indigo).
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: _cameraSourceColor(c.source),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
