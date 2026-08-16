part of '../navigation_page.dart';

extension _NavPoi on _NavigationPageState {
  Widget _poiArea() {
    return _pois.isEmpty ? _poiTypeBar() : _poiResults();
  }

  Widget _poiTypeBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final t in PoiType.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: Colors.white,
                elevation: 4,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _searchPoi(t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_poiBusy && _poiType == t)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(t.icon, size: 16, color: poiColor(t)),
                        const SizedBox(width: 6),
                        Text(
                          t.label,
                          style: const TextStyle(
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
      ),
    );
  }

  Widget _poiResults() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
          child: Row(
            children: [
              Text(
                '${_poiType?.label ?? ''} gần đây',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (_selectedPoi != null)
                TextButton(
                  onPressed: () => _rerouteToPoi(_selectedPoi!),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFFFF6F00),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  child: const Text('Đi đến', style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: () => setNavState(() {
                  _pois = [];
                  _poiType = null;
                  _selectedPoi = null;
                }),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Đóng', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _pois.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _poiCard(_pois[i]),
          ),
        ),
      ],
    );
  }

  /// Lazily-loaded category chips for the BUNDLED offline POI index (ATM,
  /// xăng, nhà hàng, …) — browse "nearest X" with no network.
  Widget _offlinePoiBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final c in (_offlinePoiCats ?? const <OfflinePoiCategory>[]))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: Colors.white,
                elevation: 4,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _searchOfflineCategory(c.key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_offlinePoiBusy && _offlinePoiCatLoading == c.key)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Text(c.emoji, style: const TextStyle(fontSize: 15)),
                        const SizedBox(width: 6),
                        Text(
                          c.label,
                          style: const TextStyle(
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
      ),
    );
  }

  Widget _poiCard(PoiResult p) {
    final d = _current == null ? 0.0 : distanceMeters(_current!, p.pos);
    final col = poiColor(p.type);
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showPoiOnMap(p),
        child: Container(
          width: 180,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(p.type.icon, size: 16, color: col),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${formatDistance(d)} • ${p.type.label}',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Find POIs of [type] for the driver. When navigating, prefer results
  /// AHEAD on the route (10–20 km window) on the SAME side of the road (so
  /// the driver doesn't have to cross / U-turn); otherwise the nearest
  /// around the car.
  Future<void> _searchPoi(PoiType type) async {
    final c = _current ?? _origin;
    if (c == null) return;
    setNavState(() {
      _poiBusy = true;
      _poiType = type;
      _selectedPoi = null;
    });
    try {
      // Search a wider radius (up to ~15 km) so there are route-ahead
      // candidates to rank; the ranking below prefers the ones up the road.
      var r = await searchPois(type, c, radius: 15000, limit: 30);
      // During navigation rank by route position (ahead + same side).
      final route = _route?.geometry ?? const <LatLng>[];
      final startIdx =
          (_engine?.snappedSegmentIndex ?? 0).clamp(0, max(0, route.length - 1))
              as int;
      r = rankPoisForRoute(r, route, startIndex: startIdx);
      if (!mounted) return;
      setNavState(() => _pois = r.take(8).toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setNavState(() => _poiBusy = false);
    }
  }

  /// "Xăng gần nhất": merge the bundled offline fuel POIs with the live
  /// Overpass fuel search around the current position and show the nearest
  /// with distance. Works fully offline; the online pass only adds stations.
  Future<void> _findNearestGas() async {
    final c = _current ?? _origin;
    if (c == null) return;
    setNavState(() {
      _poiBusy = true;
      _poiType = PoiType.fuel;
      _selectedPoi = null;
      _pois = [];
    });
    try {
      final results = <PoiResult>[
        for (final p in await poisInCategory('fuel', near: c, limit: 8))
          PoiResult(name: p.name, lat: p.lat, lng: p.lng, type: PoiType.fuel),
      ];
      // Online pass is best-effort — offline stations still show if it fails.
      try {
        for (final r in await searchPois(PoiType.fuel, c, limit: 8)) {
          final dup = results.any(
            (x) => (x.lat - r.lat).abs() < 1e-5 && (x.lng - r.lng).abs() < 1e-5,
          );
          if (!dup) results.add(r);
        }
      } catch (_) {}
      results.sort(
        (a, b) => distanceMeters(c, a.pos).compareTo(distanceMeters(c, b.pos)),
      );
      if (!mounted) return;
      setNavState(() => _pois = results.take(8).toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không tìm được trạm xăng: $e')));
      }
    } finally {
      if (mounted) setNavState(() => _poiBusy = false);
    }
  }

  /// "Điều hướng bằng Vietmap": open the real Vietmap turn-by-turn screen
  /// (official Vietmap navigation SDK) for the current destination.
  Future<void> _openVietmapNav() async {
    final dest = _destination ?? (_stops.isEmpty ? null : _stops.last.pos);
    final origin = _current ?? _origin;
    if (dest == null || origin == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Chưa có điểm đến để mở Vietmap.')),
        );
      return;
    }
    if (!VietmapConfig.hasKeys) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Thiếu khóa Vietmap để dẫn đường.')),
        );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VietmapNavScreen(
          origin: origin,
          destination: dest,
          destinationName: _destinationName,
        ),
      ),
    );
  }

  /// Load the bundled offline POI index (once) so the category chips show.
  Future<void> _ensureOfflinePoiCats() async {
    if (_offlinePoiCats != null) return;
    final cats = await offlinePoiCategories();
    if (mounted) setNavState(() => _offlinePoiCats = cats);
  }

  /// Browse one bundled offline category: show its POIs sorted by distance
  /// from the current position as search suggestions (tap → info card).
  Future<void> _searchOfflineCategory(String key) async {
    await _ensureOfflinePoiCats();
    final near = _current ?? _origin;
    setNavState(() {
      _offlinePoiBusy = true;
      _offlinePoiCatLoading = key;
      _suggestions = [];
    });
    try {
      final pois = await poisInCategory(key, near: near, limit: 8);
      if (!mounted) return;
      final cat = await offlinePoiCategory(key);
      setNavState(() {
        _offlinePoiBusy = false;
        _offlinePoiCatLoading = null;
        _suggestions = [
          for (final p in pois)
            OsmSuggestion(
              refId: 'poi/$key/${p.name}',
              display: p.name,
              lat: p.lat,
              lng: p.lng,
              source: 'poi',
              poi: p,
            ),
        ];
        _searchCtrl.text = '${cat?.emoji ?? '📍'} ${cat?.label ?? key}';
      });
    } catch (e) {
      if (mounted) {
        setNavState(() {
          _offlinePoiBusy = false;
          _offlinePoiCatLoading = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không mở được: $e')));
      }
    }
  }

  /// Show a tapped POI on the map: center the camera on it (pausing the
  /// follow) so the user can see where it is before deciding to go there.
  void _showPoiOnMap(PoiResult p) {
    setNavState(() => _selectedPoi = p);
  }

  /// Navigate to a picked POI, keeping the current navigation running.
  ///
  /// When a destination is already planned (the user is driving somewhere),
  /// the POI is ADDED as a stop / waypoint just before the destination —
  /// the final destination (and any other planned stops) is never dropped:
  /// origin → … → gas station → destination. With no planned destination the
  /// POI simply becomes the destination.
  Future<void> _rerouteToPoi(PoiResult p) async {
    final from = _current ?? _origin;
    if (from == null) return;
    try {
      final poiStop = TripStop(name: p.name, lat: p.lat, lng: p.lng);
      final alreadyPlanned = _stops.any(
        (s) => (s.lat - p.lat).abs() < 1e-5 && (s.lng - p.lng).abs() < 1e-5,
      );
      final List<TripStop> newStops;
      if (alreadyPlanned) {
        newStops = List.of(_stops); // same stop again → no change
      } else if (_stops.isEmpty) {
        newStops = [poiStop]; // no destination yet → POI becomes destination
      } else {
        newStops = [
          ..._stops.sublist(0, _stops.length - 1), // planned stops (kept)
          poiStop, // gas station waypoint (added)
          _stops.last, // final destination — never forgotten
        ];
      }
      final points = [from, for (final s in newStops) s.pos];
      final routes = await fetchAnyRoutes(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      final route = routes.first;
      if (!mounted) return;
      setNavState(() {
        _stops
          ..clear()
          ..addAll(newStops);
        _destination = newStops.last.pos;
        _route = route;
        _routeBearing = 0;
        _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
        _alternativeRoutes = routes.length > 1 ? routes : [];
        _selectedRoute = 0;
        _planPoints = points;
        _pois = [];
        _poiType = null;
        _selectedPoi = null;
        _updateDragHandles(route);
      });
      unawaited(_loadElevation(route));
      unawaited(_refreshRouteCameras());
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              alreadyPlanned
                  ? 'Đã có “${p.name}” trong hành trình.'
                  : _stops.length == 1
                  ? 'Đi đến “${p.name}”.'
                  : 'Đã thêm “${p.name}” vào điểm dừng — giữ điểm đến '
                        '${_stops.last.name}.',
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      if (_current != null) {
        final nav = _engine!.update(_current!);
        _progress = nav;
        _sendToClock(nav);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không định tuyến được: $e')));
      }
    }
  }
}
