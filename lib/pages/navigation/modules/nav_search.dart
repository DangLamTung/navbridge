part of '../navigation_page.dart';

extension _NavSearch on _NavigationPageState {
  void _onSearchChanged(String text) {
    _debounce?.cancel();
    // Typing in the END field (bottom of the directions bar) makes it the
    // active field for suggestion taps / map-taps.
    _navField = _NavField.end;
    if (text.trim().length < 2) {
      setNavState(() {
        _suggestions = [];
        _searchResults = [];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setNavState(() => _searching = true);
      try {
        // Bias online geocoding toward the live GPS position so street names
        // that exist in many cities resolve to the nearby one.
        var r = await osmAutocomplete(text.trim(), focus: _current);
        // Forced-offline + nothing in the offline cache → ask the user
        // whether to go online for this search, instead of silently showing
        // nothing (they want to CHOOSE to go online if needed).
        if (r.isEmpty && forceOffline && !_searchOfflineDeclined) {
          final goOnline = await _confirmGoOnline(
            'Không có kết quả ngoại tuyến cho “${text.trim()}”.',
          );
          if (goOnline) {
            r = await osmAutocomplete(text.trim(), focus: _current);
          } else {
            _searchOfflineDeclined = true; // don't nag again this session
          }
        }
        if (!mounted) return;
        final top = r.take(6).toList();
        setNavState(() {
          _suggestions = top;
          // During navigation, draw the found places on the map too —
          // ranked to prefer the ones AHEAD on the route (10–20 km) on the
          // same side of the road.
          _searchResults = _rankSearchForMap(top);
        });
      } catch (_) {
        if (mounted) {
          setNavState(() {
            _suggestions = [];
            _searchResults = [];
          });
        }
      } finally {
        if (mounted) setNavState(() => _searching = false);
      }
    });
  }

  /// Convert the top search suggestions into map markers, ranked by route
  /// position (ahead on the route, same side of road first). No-op in browse
  /// mode (no route) — returns [] so nothing extra is drawn.
  List<PoiResult> _rankSearchForMap(List<OsmSuggestion> s) {
    if (!_navigating) return const [];
    final route = _route?.geometry ?? const <LatLng>[];
    if (route.length < 2 || s.isEmpty) return const [];
    final startIdx =
        (_engine?.snappedSegmentIndex ?? 0).clamp(0, max(0, route.length - 1))
            as int;
    return rankPoisForRoute(
      [
        for (final x in s)
          PoiResult(
            name: x.display,
            lat: x.lat,
            lng: x.lng,
            type: PoiType.food,
          ),
      ],
      route,
      startIndex: startIdx,
    );
  }

  /// When forced-offline is active, ask the user whether to go online for an
  /// action that needs the network (search / routing). Accepting lifts the
  /// offline lock for THIS session only — the persisted setting is unchanged,
  /// so a restart goes back to forced offline. Returns true when the action
  /// may proceed online.
  Future<bool> _confirmGoOnline(String reason) async {
    if (!forceOffline) return true; // already online
    final goOnline = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cần kết nối mạng'),
        content: Text(
          '$reason\n\nBạn có muốn bật trực tuyến (tạm thời) không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Ở ngoại tuyến'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Bật trực tuyến'),
          ),
        ],
      ),
    );
    if (goOnline == true) {
      forceOffline = false; // session only — not persisted
      if (mounted) {
        setNavState(() => _offline = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Đã bật trực tuyến (phiên này)'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
    return goOnline == true;
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setNavState(() => _suggestions = []);
  }

  /// Clear the picked place card in browse mode (back to a plain search).
  void _clearPickedPlace() {
    setNavState(() => _pickedPlace = null);
  }

  Future<void> _selectSuggestion(OsmSuggestion s) async {
    _searchFocus.unfocus();
    _startFocus.unfocus();
    debugPrint(
      'SEARCH: select "${s.display}" source=${s.source} '
      'lat=${s.lat} lng=${s.lng}',
    );
    // Google Places autocomplete predictions carry only a place_id — resolve
    // coordinates + a proper address on selection.
    var lat = s.lat;
    var lng = s.lng;
    if (s.source == 'google' && s.refId.isNotEmpty) {
      final p = await googlePlaceDetails(s.refId);
      if (p == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không lấy được tọa độ địa điểm.')),
          );
        }
        return;
      }
      lat = p.$1;
      lng = p.$2;
      s = OsmSuggestion(
        refId: s.refId,
        display: p.$3.isNotEmpty ? p.$3 : s.display,
        lat: lat,
        lng: lng,
      );
    }
    // Vietmap suggestions carry no coordinates — resolve them on selection.
    if (s.source == 'vietmap' && s.refId.isNotEmpty) {
      final p = await vietmapPlace(s.refId);
      if (p == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không lấy được tọa độ địa điểm.')),
          );
        }
        return;
      }
      lat = p.$1;
      lng = p.$2;
      s = OsmSuggestion(refId: s.refId, display: s.display, lat: lat, lng: lng);
    }
    // Directions mode: the selected suggestion fills the ACTIVE field
    // (start = origin override, end = destination) and builds the route.
    if (_directionsMode) {
      if (_navField == _NavField.start) {
        setNavState(() {
          _originOverride = LatLng(lat, lng);
          _originName = s.display;
          _startCtrl.text = s.display;
          _suggestions = [];
        });
        return;
      }
      // End field → same as planning to a point.
      _planToPoint(s.display, lat, lng);
      return;
    }
    // Search (browse) mode: drop a pin + show a place card with a
    // "Chỉ đường" button (Google-Maps style) instead of building a route.
    // Bundled offline POI → wiki-style info card first (address / phone /
    // hours / description / Wikipedia), with a "Đi đến đây" button that
    // then plans the route to it.
    final poi = s.poi;
    if (poi != null && poi.hasInfo) {
      final cat = await offlinePoiCategory(poi.category);
      if (mounted && cat != null) {
        showPoiInfoCard(
          context,
          poi: poi,
          categoryLabel: cat.label,
          categoryEmoji: cat.emoji,
          onNavigate: () {
            Navigator.of(context).maybePop();
            _planToPoint(poi.name, poi.lat, poi.lng);
          },
        );
        return;
      }
    }
    setNavState(() {
      _pickedPlace = s;
      _suggestions = [];
    });
    if (mounted) {
      _map.move(LatLng(lat, lng), 15);
    }
  }

  /// The "Chỉ đường" button on the search-mode place card → enter directions
  /// mode with the picked place as the destination.
  Future<void> _directionsToPickedPlace() async {
    final p = _pickedPlace;
    if (p == null) return;
    setNavState(() {
      _directionsMode = true;
      _navField = _NavField.end;
      _pickedPlace = null;
    });
    await _planToPoint(p.display, p.lat, p.lng);
  }

  /// Switch the top bar back to plain search/browse mode (from directions).
  void _enterSearchMode() {
    setNavState(() {
      _directionsMode = false;
      _suggestions = [];
      _pickedPlace = null;
    });
  }

  /// Toggle between browse (search) mode and directions mode.
  void _toggleDirectionsMode() {
    setNavState(() {
      _directionsMode = !_directionsMode;
      _suggestions = [];
      if (!_directionsMode) _pickedPlace = null;
    });
  }

  /// Start-field text changed in directions mode — search suggests into the
  /// start field (a green dot), and picking one overrides the origin.
  void _onStartChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setNavState(() => _suggestions = []);
      return;
    }
    _navField = _NavField.start;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setNavState(() => _searching = true);
      try {
        final r = await osmAutocomplete(text.trim(), focus: _current);
        if (!mounted) return;
        setNavState(() => _suggestions = r.take(6).toList());
      } catch (_) {
        if (mounted) setNavState(() => _suggestions = []);
      } finally {
        if (mounted) setNavState(() => _searching = false);
      }
    });
  }

  /// Swap start ↔ end (Google's ⇅). The current location becomes the
  /// destination unless a start was explicitly set, in which case they swap.
  void _swapStartEnd() {
    final endText = _searchCtrl.text;
    final hasEnd = endText.isNotEmpty && _stops.isNotEmpty;
    setNavState(() {
      // Old end becomes the new start.
      if (hasEnd) {
        final lastStop = _stops.last;
        _originOverride = lastStop.pos;
        _originName = lastStop.name;
        _startCtrl.text = lastStop.name;
      } else {
        // No destination yet → put current location as the destination.
        _originOverride = null;
        _originName = '';
        _startCtrl.clear();
      }
      // Old start becomes the new end (or just plans from current location).
      _searchCtrl.text = _originName.isEmpty ? '' : _originName;
      _stops.clear();
      _route = null;
      _engine = null;
      _destination = null;
      _progress = null;
      _suggestions = [];
      _planPoints = [];
      _dragHandles = [];
      _alternativeRoutes = [];
      _selectedRoute = 0;
      _elevation = null;
      _navField = _NavField.end;
    });
    if (hasEnd) {
      unawaited(_buildPlanRoute());
    }
  }

  /// "Thêm điểm dừng" in directions mode: insert a stop before the final
  /// destination and re-plan.
  Future<void> _addDirectionsStop() async {
    final stop = await _pickViaPoint();
    if (stop == null) return;
    setNavState(() {
      if (_stops.isNotEmpty) {
        _stops.insert(_stops.length - 1, stop);
      } else {
        _stops.add(stop);
      }
    });
    await _buildPlanRoute();
  }

  /// Pick a via point interactively — asks the user to tap the map (or uses
  /// the current camera centre as a shortcut). Returns null if cancelled.
  Future<TripStop?> _pickViaPoint() async {
    // Shortcut: if the map is already panned somewhere, use its centre.
    try {
      final c = _map.camera.center;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Thêm điểm dừng'),
          content: const Text(
            'Bấm "Dùng vị trí này" để thêm điểm dừng tại giữa màn hình, '
            'hoặc "Huỷ" rồi chạm vào bản đồ.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Huỷ'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Dùng vị trí này'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return null;
      return TripStop(name: 'Điểm giữa', lat: c.latitude, lng: c.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Add [name]@[lat]/[lng] as the destination and build the route.
  Future<void> _planToPoint(String name, double lat, double lng) async {
    if (!mounted) return;
    setNavState(() {
      _suggestions = [];
      _building = true;
      _searchCtrl.text = name;
      _stops.add(TripStop(name: name, lat: lat, lng: lng));
      _destination = LatLng(lat, lng);
      _searchCtrl.clear();
    });
    try {
      await _buildPlanRoute();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không tìm được địa điểm: $e')));
      }
    } finally {
      if (mounted) setNavState(() => _building = false);
    }
  }

  /// Route through all planned stops (origin → stop1 → … → last stop).
  Future<void> _buildPlanRoute() async {
    if (_stops.isEmpty) return;
    final seq = ++_planSeq; // supersede any build still in flight
    final origin = _originOverride ?? await _resolveOrigin();
    if (origin == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không lấy được vị trí xuất phát.')),
        );
      }
      return;
    }
    if (seq != _planSeq) return; // a newer build started — drop this one
    _origin = origin;
    _current ??= origin;
    final points = [origin, for (final s in _stops) s.pos];
    OsrmRoute route;
    List<OsrmRoute> alternatives = [];
    try {
      // OSRM / Vietmap can return up to 3 route options (best first).
      final routes = await fetchAnyRoutes(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      route = routes.first;
      alternatives = routes.length > 1 ? routes : [];
    } catch (e) {
      // Offline and no matching offline data → offer to go online instead
      // of just failing (the user wants to choose if needed).
      debugPrint('PLAN: route failed: $e');
      if (!forceOffline) rethrow;
      final msg = _routeProfile == RouteProfile.car
          ? 'Chưa có bộ dữ liệu chỉ đường ngoại tuyến cho tuyến này.'
          : 'Bộ dữ liệu ngoại tuyến chỉ hỗ trợ ô tô — cần trực tuyến cho ${_routeProfile.label.toLowerCase()}. ';
      final goOnline = await _confirmGoOnline(msg);
      if (!mounted || seq != _planSeq) return;
      if (!goOnline) {
        // Clear feedback instead of silently doing nothing: offline routing
        // only covers the downloaded region (the HCMC graph) — a searched
        // place outside it can't be routed without the network.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Chưa có dữ liệu chỉ đường ngoại tuyến cho khu vực này.\n'
              'Hãy tải bộ dữ liệu cho khu vực (⚙) hoặc bật trực tuyến.',
            ),
          ),
        );
        return;
      }
      route = await fetchOsrmRoute(
        points,
        profile: _routeProfile.osrm,
        exclude: osrmExclude(
          avoidHighway: _avoidHighway,
          avoidFerry: _avoidFerry,
        ),
      );
    }
    debugPrint(
      'PLAN: BUILD ok pts=${points.length} '
      'dist=${route.distance}m stops=${route.stopCumulative.length} '
      'alts=${alternatives.length}',
    );
    if (!mounted || seq != _planSeq) return;
    setNavState(() {
      _route = route;
      _alternativeRoutes = alternatives;
      _selectedRoute = 0;
      _planPoints = points;
      _routeBearing = 0;
      _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      _destination = _stops.last.pos;
      _navigating = false;
      _progress = null;
      _routeStartIndex = 0; // brand-new route → draw the whole thing
      _updateDragHandles(route);
    });
    unawaited(_loadElevation(route));
    unawaited(_refreshRouteCameras());
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  /// Switch to alternative route [i] (Google's tap-to-choose preview).
  void _selectAlternative(int i) {
    if (i < 0 || i >= _alternativeRoutes.length || i == _selectedRoute) return;
    final route = _alternativeRoutes[i];
    debugPrint(
      'PLAN: alternative $i selected '
      'dist=${route.distance}m',
    );
    setNavState(() {
      _selectedRoute = i;
      _route = route;
      _routeBearing = 0;
      _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      _updateDragHandles(route);
    });
    unawaited(_loadElevation(route));
    unawaited(_refreshRouteCameras());
    if (_planPoints.length >= 2) {
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(_planPoints),
          padding: const EdgeInsets.all(60),
        ),
      );
    }
  }

  List<String> _engineStopNames(OsrmRoute route) =>
      route.stopCumulative.length == _stops.length
      ? [for (final s in _stops) s.name]
      : const [];

  /// Switch the road type (ô tô / xe máy / xe đạp / đi bộ) and re-plan.
  void _setRouteProfile(RouteProfile p) {
    if (p == _routeProfile) return;
    setNavState(() => _routeProfile = p);
    // Keep Settings → "Phương tiện" (speed-limit defaults) in sync so
    // "Xe máy" is ONE mode, not two separate controls doing different
    // things. Bicycle/walking don't change the speed-limit vehicle.
    final v = switch (p) {
      RouteProfile.motorbike => 'motorbike',
      RouteProfile.car => 'car',
      RouteProfile.bicycle || RouteProfile.walking => vehicleType,
    };
    if (v != vehicleType) {
      vehicleType = v;
      unawaited(_persistVehicleType(v));
    }
    if (_stops.isNotEmpty) {
      _buildPlanRoute(); // re-route with the new mode of transport
    }
  }

  /// Persist a new speed-limit vehicle (keeps ALL settings fields).
  Future<void> _persistVehicleType(String v) async {
    final s = await loadSettings();
    await saveSettings(
      AppSettings(
        forceOffline: s.forceOffline,
        dataSource: s.dataSource,
        vehicleType: v,
        speedOverride: s.speedOverride,
        geocodingProvider: s.geocodingProvider,
        routingEngine: s.routingEngine,
        smoothCamera: s.smoothCamera,
        cameraAlerts: s.cameraAlerts,
        pipAspect: s.pipAspect,
        ridingMode: s.ridingMode,
        simpleMode: s.simpleMode,
      ),
    );
  }

  void _moveStop(int index, int delta) {
    final i = index + delta;
    if (i < 0 || i >= _stops.length) return;
    setNavState(() {
      final s = _stops.removeAt(index);
      _stops.insert(i, s);
    });
    _buildPlanRoute();
  }

  void _removeStop(int index) {
    setNavState(() => _stops.removeAt(index));
    if (_stops.isEmpty) {
      setNavState(() {
        _route = null;
        _engine = null;
        _destination = null;
        _progress = null;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _planPoints = [];
        _showSteps = false;
        _dragHandles = [];
        _elevation = null;
        _pois = [];
        _poiType = null;
      });
      return;
    }
    _buildPlanRoute();
  }

  Future<void> _savePlan() async {
    if (_stops.isEmpty) return;
    final plans = await loadPlans();
    final plan = TripPlan(
      name: _stops.length == 1
          ? _stops.first.name
          : 'Chuyến ${_stops.length} điểm',
      createdAt: DateTime.now(),
      stops: List.of(_stops),
    );
    plans.insert(0, plan);
    await savePlans(plans);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã lưu kế hoạch chuyến đi.')),
      );
    }
  }

  /// Best-effort start position: live fix, last known, or the app default.
  /// Never throws; falls back to the default city (HCMC) when GPS is
  /// unavailable so route planning still work.
  Future<LatLng?> _resolveOrigin() async {
    final cur = _current;
    if (cur != null) return cur;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LatLng(last.latitude, last.longitude);
    } catch (_) {
      // ignore and try the live fix below
    }
    try {
      final p = await Geolocator.getCurrentPosition();
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return const LatLng(10.8231, 106.6297); // default center (HCMC)
    }
  }

  Future<void> _voiceSearchAndNavigate(String query, bool navigate) async {
    if (query.isEmpty) {
      _voice.speak('Bạn muốn tìm địa điểm nào?');
      return;
    }
    _searchCtrl.text = query;
    // POI category phrases ("cà phê võng", "nhà hàng", "trạm xăng", …) →
    // run the quick POI search (route-aware) instead of a plain geocode,
    // so "tìm cà phê võng" finds hammock cafés, not a street match.
    final type = _poiTypeForQuery(query);
    if (type != null) {
      _voice.speak('Đang tìm ${type.label.toLowerCase()}…');
      await _searchPoi(type);
      if (navigate && _pois.isNotEmpty && mounted) {
        final best = _pois.first;
        _voice.speak('Đã tìm thấy ${best.name}, bắt đầu chỉ đường.');
        await _rerouteToPoi(best);
      }
      return;
    }
    final r = await osmAutocomplete(query, focus: _current);
    if (r.isEmpty) {
      _voice.speak('Không tìm thấy địa điểm $query.');
      return;
    }
    final s = r.first;
    _voice.speak('Đã tìm thấy ${s.display}.');
    await _selectSuggestion(s);
    if (navigate && mounted) {
      _voice.speak('Bắt đầu chỉ đường.');
      _startNavigation();
    }
  }

  /// Map a voice/search phrase to a quick-POI category, or null for a plain
  /// place search. Handles common Vietnamese terms (incl. "cà phê võng").
  PoiType? _poiTypeForQuery(String q) {
    final s = _stripDiacritics(q.toLowerCase());
    if (s.contains('ca phe vong') || s.contains('cafe vong')) {
      return PoiType.cafeVong;
    }
    if (s.contains('nha hang') ||
        s.contains('an uong') ||
        s.contains('quan an')) {
      return PoiType.food;
    }
    if (s.contains('tram xang') || s.contains('xang')) {
      return PoiType.fuel;
    }
    if (s.contains('khach san')) {
      return PoiType.hotel;
    }
    if (s.contains('cay atm')) {
      return PoiType.atm;
    }
    if (s.contains('benh vien') || s.contains('nha thuoc')) {
      return PoiType.hospital;
    }
    return null;
  }
}

/// Minimal diacritic stripper for voice/POI phrase matching ("cà phê võng" →
/// "ca phe vong"), so category detection works whether speech recognition
/// returns accented or unaccented Vietnamese.
String _stripDiacritics(String s) {
  const map = {
    'à': 'a',
    'á': 'a',
    'ả': 'a',
    'ã': 'a',
    'ạ': 'a',
    'ă': 'a',
    'ằ': 'a',
    'ắ': 'a',
    'ẳ': 'a',
    'ẵ': 'a',
    'ặ': 'a',
    'â': 'a',
    'ầ': 'a',
    'ấ': 'a',
    'ẩ': 'a',
    'ẫ': 'a',
    'ậ': 'a',
    'è': 'e',
    'é': 'e',
    'ẻ': 'e',
    'ẽ': 'e',
    'ẹ': 'e',
    'ê': 'e',
    'ề': 'e',
    'ế': 'e',
    'ể': 'e',
    'ễ': 'e',
    'ệ': 'e',
    'ì': 'i',
    'í': 'i',
    'ỉ': 'i',
    'ĩ': 'i',
    'ị': 'i',
    'ò': 'o',
    'ó': 'o',
    'ỏ': 'o',
    'õ': 'o',
    'ọ': 'o',
    'ô': 'o',
    'ồ': 'o',
    'ố': 'o',
    'ổ': 'o',
    'ỗ': 'o',
    'ộ': 'o',
    'ơ': 'o',
    'ờ': 'o',
    'ớ': 'o',
    'ở': 'o',
    'ỡ': 'o',
    'ợ': 'o',
    'ù': 'u',
    'ú': 'u',
    'ủ': 'u',
    'ũ': 'u',
    'ụ': 'u',
    'ư': 'u',
    'ừ': 'u',
    'ứ': 'u',
    'ử': 'u',
    'ữ': 'u',
    'ự': 'u',
    'ỳ': 'y',
    'ý': 'y',
    'ỷ': 'y',
    'ỹ': 'y',
    'ỵ': 'y',
    'đ': 'd',
    'À': 'A',
    'Á': 'A',
    'Ả': 'A',
    'Ã': 'A',
    'Ạ': 'A',
    'Ă': 'A',
    'Ằ': 'A',
    'Ắ': 'A',
    'Ẳ': 'A',
    'Ẵ': 'A',
    'Ặ': 'A',
    'Â': 'A',
    'Ầ': 'A',
    'Ấ': 'A',
    'Ẩ': 'A',
    'Ẫ': 'A',
    'Ậ': 'A',
    'È': 'E',
    'É': 'E',
    'Ẻ': 'E',
    'Ẽ': 'E',
    'Ẹ': 'E',
    'Ê': 'E',
    'Ề': 'E',
    'Ế': 'E',
    'Ể': 'E',
    'Ễ': 'E',
    'Ệ': 'E',
    'Ì': 'I',
    'Í': 'I',
    'Ỉ': 'I',
    'Ĩ': 'I',
    'Ị': 'I',
    'Ò': 'O',
    'Ó': 'O',
    'Ỏ': 'O',
    'Õ': 'O',
    'Ọ': 'O',
    'Ô': 'O',
    'Ố': 'O',
    'Ổ': 'O',
    'Ỗ': 'O',
    'Ộ': 'O',
    'Ơ': 'O',
    'Ờ': 'O',
    'Ớ': 'O',
    'Ở': 'O',
    'Ỡ': 'O',
    'Ợ': 'O',
    'Ù': 'U',
    'Ú': 'U',
    'Ủ': 'U',
    'Ũ': 'U',
    'Ụ': 'U',
    'Ư': 'U',
    'Ừ': 'U',
    'Ứ': 'U',
    'Ử': 'U',
    'Ữ': 'U',
    'Ự': 'U',
    'Ỳ': 'Y',
    'Ý': 'Y',
    'Ỷ': 'Y',
    'Ỹ': 'Y',
    'Ỵ': 'Y',
    'Đ': 'D',
  };
  final b = StringBuffer();
  for (final ch in s.split('')) {
    b.write(map[ch] ?? ch);
  }
  return b.toString();
}
