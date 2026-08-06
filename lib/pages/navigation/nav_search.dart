part of 'navigation_page.dart';

extension _NavSearch on _NavigationPageState {

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setNavState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setNavState(() => _searching = true);
      try {
        var r = await osmAutocomplete(text.trim());
        // Forced-offline + nothing in the offline cache → ask the user
        // whether to go online for this search, instead of silently showing
        // nothing (they want to CHOOSE to go online if needed).
        if (r.isEmpty && forceOffline && !_searchOfflineDeclined) {
          final goOnline = await _confirmGoOnline(
            'Không có kết quả ngoại tuyến cho “${text.trim()}”.',
          );
          if (goOnline) {
            r = await osmAutocomplete(text.trim());
          } else {
            _searchOfflineDeclined = true; // don't nag again this session
          }
        }
        if (!mounted) return;
        setNavState(() => _suggestions = r.take(6).toList());
      } catch (_) {
        if (mounted) setNavState(() => _suggestions = []);
      } finally {
        if (mounted) setNavState(() => _searching = false);
      }
    });
  }

  Future<bool> _confirmGoOnline(String reason) async {
    if (!forceOffline) return true; // already online
    // Test harness: no user to tap the dialog — auto-decline so the offline
    // NAVTEST fails fast and logs instead of hanging.
    if (const bool.fromEnvironment('NAVTEST') ||
        const bool.fromEnvironment('NAVTEST_OFFLINE') ||
        const bool.fromEnvironment('NAVTEST_LONG') ||
        const bool.fromEnvironment('NAVTEST_MOUNTAIN')) {
      debugPrint('NAVTEST: offline data missing — auto-declining go-online');
      return false;
    }
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
  Future<void> _selectSuggestion(OsmSuggestion s) async {
    _searchFocus.unfocus();
    debugPrint(
      'SEARCH: select "${s.display}" source=${s.source} '
      'lat=${s.lat} lng=${s.lng}',
    );
    // Vietmap suggestions carry no coordinates — resolve them on selection.
    var lat = s.lat;
    var lng = s.lng;
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
    _planToPoint(s.display, lat, lng);
  }

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

  Future<void> _buildPlanRoute() async {
    if (_stops.isEmpty) return;
    final origin = await _resolveOrigin();
    if (origin == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không lấy được vị trí xuất phát.')),
        );
      }
      return;
    }
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
      if (!mounted) return;
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
    if (!mounted) return;
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
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

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
    if (_stops.isNotEmpty) {
      _buildPlanRoute(); // re-route with the new mode of transport
    }
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
    final r = await osmAutocomplete(query);
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
}
