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

  /// Bottom-sheet details for a road-sign marker tapped on the map: kind,
  /// posted speed limit, name, and data source (Vietmap / OSM / Waze).
  void _showSignInfo(RoadSign s) {
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
                  SignIcon(kind: s.kind, value: s.value, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.kind.label,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (s.value != null && s.value! > 0)
                          Text(
                            'Tốc độ giới hạn: ${s.value} km/h',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (s.name.isNotEmpty && s.name != s.kind.label) ...[
                const SizedBox(height: 10),
                Text(
                  s.name,
                  style: TextStyle(fontSize: 13, color: Colors.grey[800]),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _cameraSourceColor(s.source),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Nguồn dữ liệu: ${cameraSourceLabel(s.source)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${s.lat.toStringAsFixed(5)}, ${s.lng.toStringAsFixed(5)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[500],
                      fontFamily: 'monospace',
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
    // Browse map: load the camera/sign index LAZILY (after the first build)
    // so cold start stays fast but cameras + signs still appear on browse.
    if (!_camerasRequested) {
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
            onPositionChanged: (pos, hasGesture) {
              _syncOverlayVisibility();
              if ((pos.zoom - _cameraZoom).abs() >= 0.35 ||
                  (!hasGesture && (pos.zoom - _cameraZoom).abs() >= 0.05)) {
                setNavState(() {
                  _cameraZoom = pos.zoom;
                });
              } else {
                _cameraZoom = pos.zoom;
              }
              if (!hasGesture && !_navigating) {
                final c = _nearCamCenter;
                if (c == null ||
                    (pos.center.latitude - c.latitude).abs() > 0.03 ||
                    (pos.center.longitude - c.longitude).abs() > 0.03) {
                  _refreshNearCameras(pos.center);
                }
              }
            },
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
                  // Resolve a real road/place name for the tapped start.
                  reverseGeocode(tapPos).then((addr) {
                    if (!mounted || addr.isEmpty) return;
                    setNavState(() {
                      _originName = addr;
                      _startCtrl.text = addr;
                    });
                  });
                } else {
                  _planToPoint(
                    'Điểm trên bản đồ',
                    tapPos.latitude,
                    tapPos.longitude,
                  );
                  // Resolve a real road/place name for the tapped destination.
                  reverseGeocode(tapPos).then((addr) {
                    if (!mounted || addr.isEmpty) return;
                    setNavState(() {
                      final idx = _stops.length - 1;
                      if (idx >= 0 &&
                          _stops[idx].lat == tapPos.latitude &&
                          _stops[idx].lng == tapPos.longitude) {
                        _stops[idx] = TripStop(
                          name: addr,
                          lat: tapPos.latitude,
                          lng: tapPos.longitude,
                        );
                      }
                    });
                  });
                }
                return;
              }
              if (_navigating || _alternativeRoutes.length <= 1) return;
              // Scale tap tolerance to ~28 screen pixels based on current zoom
              // so the driver can tap alternative routes easily even when zoomed out.
              var threshold = 45.0;
              try {
                final zoom = _map.camera.zoom;
                final cosLat = cos(tapPos.latitude * pi / 180);
                final mPerPx = 156543.03392 * cosLat / pow(2, zoom);
                threshold = max(45.0, 28.0 * mPerPx);
              } catch (_) {}

              int? bestIdx;
              var bestDist = double.infinity;
              for (var i = 0; i < _alternativeRoutes.length; i++) {
                if (i == _selectedRoute) continue;
                final d = _distToLine(tapPos, _alternativeRoutes[i].geometry);
                if (d < threshold && d < bestDist) {
                  bestDist = d;
                  bestIdx = i;
                }
              }
              if (bestIdx != null) {
                _selectAlternative(bestIdx);
                return;
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
                // Road-sign layer: real sign icons near the user (cấm vượt /
                // STOP / khu dân cư …). Density + visibility follow zoom.
                for (final s in _signSlice(_cameraZoom))
                  Marker(
                    point: s.pos,
                    width: 32,
                    height: 32,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showSignInfo(s),
                      child: SignIcon(kind: s.kind, value: s.value, size: 30),
                    ),
                  ),
                // Camera layer: colored dot per focus (speed / red-light /
                // general). A single circle (no separate 📷 text) so it fits
                // the 26×26 marker box. A tiny corner dot marks the source
                // (waze/police/osm). Only NEAR-THE-USER cameras are drawn,
                // density-culled by zoom (fewer when zoomed out), and HIDDEN
                // when zoomed in further (>= z16).
                if (_camerasVisible(_cameraZoom))
                  for (final c in _cameraSlice(_cameraZoom))
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
        // Basemap layer switcher, floating on the map (Google Maps style).
        Positioned(
          left: 12,
          bottom: 20,
          child: _layerMenuButton(),
        ),
      ],
    );
  }

  /// Camera visibility on browse/route map: only if camera alerts are enabled,
  /// and hidden when zoomed out past regional level (z < 10).
  bool _camerasVisible(double zoom) => cameraAlerts && zoom >= 10.0;

  /// Marker density cap: fewer markers when zoomed out, more when zoomed in.
  int _markerLimit(double zoom) => ((zoom - 12) * 40).round().clamp(20, 120);

  /// Decimates [items] evenly across the sequence so the route is sampled
  /// uniformly from start to end without clumping or dropping the tail.
  List<T> _decimateList<T>(List<T> items, int cap) {
    if (items.length <= cap) return items;
    if (cap <= 0) return const [];
    final step = items.length / cap;
    return List.generate(cap, (i) => items[(i * step).floor()]);
  }

  List<OfflineCamera> _cameraSlice(double zoom) {
    if (_route != null) {
      // In navigation or prepare-to-navigate mode with an active route:
      // Cap cameras to ~15-60 markers based on zoom so combined markers
      // (signs + cameras) stay strictly within 100-200 important markers.
      final important = _routeCameras
          .where((c) => c.focus == 'speed' || c.focus == 'red_light')
          .toList();
      final pool = important.isNotEmpty ? important : _routeCameras;
      final cap = ((zoom - 10.0) * 7 + 15).round().clamp(15, 60);
      return _decimateList(pool, cap);
    }

    final n = _markerLimit(zoom);
    return _nearCameras.length > n ? _nearCameras.sublist(0, n) : _nearCameras;
  }

  /// Road signs on the map:
  /// - When an active route exists (_route != null, i.e. navigation or prepare-to-navigate):
  ///   Strictly limits to important signs (speed limits, khu dân cư, cấm vượt, STOP, etc.),
  ///   clustering/decimating evenly along the route when zoomed out (20 signs at z11)
  ///   and smoothly increasing up to ~140 signs when zoomed in.
  /// - When browsing without a route (_route == null):
  ///   Uses near-user signs (20-30 important signs when zoomed out, up to 70 when zoomed in).
  /// Hidden completely at z < 11.0 (regional overview).
  List<RoadSign> _signSlice(double zoom) {
    if (zoom < 11.0) return const [];

    if (_route != null) {
      // Limit to important regulatory & safety signs on route
      final important = _routeSigns.where((s) => s.isImportant).toList();
      final pool = important.isNotEmpty ? important : _routeSigns;
      final cap = ((zoom - 11.0) * 24 + 20).round().clamp(20, 140);
      return _decimateList(pool, cap);
    }

    final list = _nearSigns;
    final isZoomedOut = zoom < 14.5;
    if (isZoomedOut) {
      final important = list.where((s) => s.isImportant).toList();
      final cap = ((zoom - 11.0) * 3 + 20).round().clamp(20, 30);
      return important.length > cap ? important.sublist(0, cap) : important;
    }

    final n = ((zoom - 14.5) * 20 + 30).round().clamp(30, 70);
    return list.length > n ? list.sublist(0, n) : list;
  }

  /// Floating basemap layer picker (OpenStreetMap / CARTO / ESRI / topo).
  Widget _layerMenuButton() {
    const options = {
      'osm': 'OpenStreetMap',
      'esri-street': 'ESRI Street',
      'esri': 'ESRI Satellite',
      'topo': 'OpenTopoMap',
    };
    return PopupMenuButton<String>(
      tooltip: 'Lớp bản đồ',
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) => _setTileSource(v),
      itemBuilder: (ctx) => [
        for (final e in options.entries)
          PopupMenuItem<String>(
            value: e.key,
            child: Row(
              children: [
                Icon(
                  e.key == _tileSource
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: const Color(0xFF4285F4),
                ),
                const SizedBox(width: 8),
                Text(e.value),
              ],
            ),
          ),
      ],
      child: const CircleAvatar(
        radius: 20,
        backgroundColor: Colors.white,
        child: Icon(Icons.layers, color: Color(0xFF5F6368)),
      ),
    );
  }
}
