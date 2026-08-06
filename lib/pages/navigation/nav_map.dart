part of 'navigation_page.dart';

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

  void _cycleCarIcon() {
    final i = kCarIcons.indexOf(_carIcon);
    setNavState(() => _carIcon = kCarIcons[(i + 1) % kCarIcons.length]);
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

  void _toggleNight() {
    setNavState(() => _nightMode = !_nightMode);
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
}
