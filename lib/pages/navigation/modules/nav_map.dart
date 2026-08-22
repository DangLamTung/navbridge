part of '../navigation_page.dart';

/// Map rendering + camera + basemap layers for the browse (raster FlutterMap)
/// page. The nav-mode vector map lives in `ui/vector_nav_map.dart`; this only
/// owns the raster preview map + its controls (zoom / overview / locate /
/// layer cycle / night + car icon).
extension _NavMap on _NavigationPageState {
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
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
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
            if (radarOn && _radarLayerUrl != null)
              Opacity(
                opacity: 0.55,
                child: TileLayer(
                  urlTemplate: _radarLayerUrl!,
                  userAgentPackageName: 'com.navbridge.app',
                  tileProvider: NetworkTileProvider(),
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
                  maxNativeZoom: 6,
                ),
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
                // old dot+tag Column overflowed by 5 px for every camera.
                if (cameraAlerts)
                  for (final c in _cameras)
                    Marker(
                      point: c.pos,
                      width: 26,
                      height: 26,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _cameraFocusColor(c.focus),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black38, blurRadius: 4),
                          ],
                        ),
                        child: const CctvIcon(size: 11),
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
