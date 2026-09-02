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
  /// Bundled offline POI category key for a [PoiType] (null = no offline
  /// data for that category). NOTE: the offline index uses `restaurant` (not
  /// `food`) for eating places.
  String? _offlineKeyForPoiType(PoiType t) => switch (t) {
    PoiType.fuel => 'fuel',
    PoiType.charging => null, // no bundled charging data yet
    PoiType.food => 'restaurant',
    PoiType.cafeVong => 'cafe',
    PoiType.hotel => 'hotel',
    PoiType.atm => 'atm',
    PoiType.hospital => 'hospital',
    PoiType.parking => 'parking',
  };

  /// True when [a] and [b] are the same station (within ~40 m) — the offline
  /// + online merge used to show one station twice at slightly different
  /// coordinates.
  bool _sameStation(PoiResult a, PoiResult b) =>
      distanceMeters(a.pos, b.pos) < 40;

  /// Vietmap (VN-native) POI pass — autocomplete "trạm xăng"/"trạm sạc" then
  /// resolve coordinates. Best-effort: empty without VIETMAP_API_KEY.
  Future<List<PoiResult>> _vietmapPois(
    String query,
    PoiType type,
    LatLng c, {
    int limit = 8,
    String? exclude,
  }) async {
    final pois = await vietmapPoiSearch(query, c, limit: limit);
    final rx = exclude == null ? null : RegExp(exclude, caseSensitive: false);
    return [
      for (final p in pois)
        if (rx == null || !rx.hasMatch(p.name))
          PoiResult(name: p.name, lat: p.lat, lng: p.lng, type: type),
    ];
  }

  /// Google rating used for ranking — treated as 0 (ignored) when there is
  /// no rating or fewer than [minReviews] reviews, so a single 5★ review
  /// can't beat a well-reviewed 4.8.
  static double _ratingKey(PoiResult p, {int minReviews = 5}) {
    final r = p.rating ?? 0;
    if (r < 0.1 || (p.userRatingsTotal ?? 0) < minReviews) return 0;
    return r;
  }

  /// Centers for the ±15 km route-corridor POI search: the car + points
  /// ahead on the route every ~10 km (each Google search uses a 15 km radius,
  /// so together they cover the corridor along the driving path, up to
  /// ~30 km ahead).
  List<LatLng> _poiCorridorCenters(LatLng car, List<LatLng> route) {
    if (route.length < 2) return [car];
    final startIdx = (_engine?.snappedSegmentIndex ?? 0).clamp(
      0,
      route.length - 1,
    );
    final out = <LatLng>[car];
    double cum = 0;
    for (var i = startIdx; i + 1 < route.length && out.length < 4; i++) {
      cum += distanceMeters(route[i], route[i + 1]);
      if (cum >= 10000) {
        out.add(route[i + 1]);
        cum = 0;
      }
    }
    if (out.length == 1 && startIdx < route.length) out.add(route.last);
    return out;
  }

  /// Search the [type] quick-POI category and show the best candidates.
  /// OFFLINE-FIRST: the bundled Vietnam POI index is merged with the live
  /// Overpass search, so the chips (Xăng / Ăn uống / …) work with no data
  /// signal — previously they only did an online query and failed with
  /// "Không tìm thấy …" whenever the phone was offline. The online pass
  /// just adds more/fresher results on top.
  Future<void> _searchPoi(PoiType type) async {
    final c = _current ?? _origin;
    if (c == null) return;
    final route = _route?.geometry ?? const <LatLng>[];
    // ±15 km corridor along the route: the car + points ahead every ~10 km
    // (each Google search uses a 15 km radius, so together they cover the
    // corridor the driver is heading into, not just a circle around the car).
    final centers = _poiCorridorCenters(c, route);
    setNavState(() {
      _poiBusy = true;
      _poiType = type;
      _selectedPoi = null;
      _pois = [];
    });
    try {
      final results = <PoiResult>[];
      // Offline pass first (bundled Vietnam POIs).
      final key = _offlineKeyForPoiType(type);
      if (key != null) {
        for (final p in await poisInCategory(key, near: c, limit: 12)) {
          results.add(
            PoiResult(name: p.name, lat: p.lat, lng: p.lng, type: type),
          );
        }
      }
      // Online Overpass pass is best-effort — offline results still show if
      // it fails (or the phone is offline).
      try {
        for (final r in await searchPois(type, c, radius: 10000, limit: 30)) {
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      // Google Places pass — the best VN coverage with REAL ratings, searched
      // along the ±15 km route corridor (nearest gas / highest-rated food).
      try {
        for (final r in await googlePoiSearch(type, centers, radius: 15000)) {
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      // Vietmap pass — real VN place names (e.g. "Petrolimex") using the key
      // the app already has; best-effort. Only for xăng / trạm sạc.
      try {
        final List<PoiResult> vm;
        if (type == PoiType.fuel) {
          vm = await _vietmapPois('trạm xăng', type, c, limit: 8);
        } else if (type == PoiType.charging) {
          vm = await _vietmapPois(
            'trạm sạc',
            type,
            c,
            limit: 8,
            exclude: 'gội đầu|massage|dưỡng sinh|trạm sạc đầu',
          );
        } else {
          vm = const [];
        }
        for (final r in vm) {
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      if (results.isEmpty) {
        throw Exception('Không tìm thấy ${type.label.toLowerCase()} gần đây');
      }
      List<PoiResult> ranked;
      if (type == PoiType.food || type == PoiType.cafeVong) {
        // Nhà hàng: highest rating first (with a sane minimum review count so
        // one 5★ review doesn't top the list), then review count, then
        // nearest.
        results.sort((a, b) {
          final ra = _ratingKey(a);
          final rb = _ratingKey(b);
          if (ra != rb) return rb.compareTo(ra);
          final va = a.userRatingsTotal ?? 0;
          final vb = b.userRatingsTotal ?? 0;
          if (va != vb) return vb.compareTo(va);
          return distanceMeters(c, a.pos).compareTo(distanceMeters(c, b.pos));
        });
        ranked = results;
      } else if (type == PoiType.fuel) {
        // Trạm xăng: prefer the stations AHEAD on the route (the next place
        // we're going to reach) — not ones behind, or the app points back. On
        // a route, ahead-distance + travel-side wins; otherwise nearest.
        if (route.length > 2) {
          final startIdx =
              (_engine?.snappedSegmentIndex ?? 0).clamp(
                    0,
                    max(0, route.length - 1),
                  )
                  as int;
          ranked = rankPoisForRoute(results, route, startIndex: startIdx);
        } else {
          results.sort(
            (a, b) =>
                distanceMeters(c, a.pos).compareTo(distanceMeters(c, b.pos)),
          );
          ranked = results;
        }
      } else if (route.length > 2) {
        final startIdx =
            (_engine?.snappedSegmentIndex ?? 0).clamp(
                  0,
                  max(0, route.length - 1),
                )
                as int;
        ranked = rankPoisForRoute(results, route, startIndex: startIdx);
      } else {
        results.sort(
          (a, b) =>
              distanceMeters(c, a.pos).compareTo(distanceMeters(c, b.pos)),
        );
        ranked = results;
      }
      if (!mounted) return;
      setNavState(() => _pois = ranked.take(8).toList());
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
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      // Vietmap pass — real VN gas stations ("Petrolimex"…) via the app's key.
      try {
        for (final r in await _vietmapPois(
          'trạm xăng',
          PoiType.fuel,
          c,
          limit: 8,
        )) {
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      // Google pass — nearest real gas stations (rankby=distance around the
      // car) with names/ratings from Google Places.
      try {
        for (final r in await googlePoiSearch(
          PoiType.fuel,
          [c],
          radius: 15000,
          limit: 20,
        )) {
          if (!results.any((x) => _sameStation(x, r))) results.add(r);
        }
      } catch (_) {}
      // Prefer stations AHEAD on the route (the next place we'll reach), so
      // "xăng gần nhất" never points back the way we came.
      List<PoiResult> ranked;
      final route = _route?.geometry ?? const <LatLng>[];
      if (route.length > 2) {
        final startIdx =
            (_engine?.snappedSegmentIndex ?? 0).clamp(
                  0,
                  max(0, route.length - 1),
                )
                as int;
        ranked = rankPoisForRoute(results, route, startIndex: startIdx);
      } else {
        results.sort(
          (a, b) =>
              distanceMeters(c, a.pos).compareTo(distanceMeters(c, b.pos)),
        );
        ranked = results;
      }
      if (!mounted) return;
      setNavState(() => _pois = ranked.take(8).toList());
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

  /// Start watching for a LONG fuel gap ahead (a section with no gas station)
  /// while navigating, so the driver can prepare. Runs on a background timer
  /// (~2 min) — the airport/no-gas warning is only useful when it comes in
  /// time, not every second.
  void _startFuelWatch() {
    _stopFuelWatch();
    _fuelWarned = false;
    unawaited(_checkFuelGapAhead());
    _fuelTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(_checkFuelGapAhead());
    });
  }

  void _stopFuelWatch() {
    _fuelTimer?.cancel();
    _fuelTimer = null;
  }

  /// Nearest fuel station AHEAD on the route (project each onto the route;
  /// ignore ones well behind). When the next one is far (>30 km) or there is
  /// none within ~60 km, warn the driver ONCE per gap to prepare — notified
  /// so it's seen with the screen off. Re-arms when a station is reached.
  Future<void> _checkFuelGapAhead() async {
    if (!_navigating && !_simulating) return;
    final c = _current ?? _origin;
    final route = _route?.geometry ?? const <LatLng>[];
    if (c == null || route.length < 2) return;
    final results = <PoiResult>[
      for (final p in await poisInCategory('fuel', near: c, limit: 24))
        PoiResult(name: p.name, lat: p.lat, lng: p.lng, type: PoiType.fuel),
    ];
    try {
      for (final r in await searchPois(
        PoiType.fuel,
        c,
        radius: 50000,
        limit: 30,
      )) {
        if (!results.any((x) => _sameStation(x, r))) results.add(r);
      }
    } catch (_) {}
    if (results.isEmpty) return;
    final startIdx =
        (_engine?.snappedSegmentIndex ?? 0).clamp(0, max(0, route.length - 1))
            as int;
    double? nextGas; // nearest station on/near the route, AHEAD of the car
    for (final r in results) {
      final proj = projectOnRoute(route, r.pos, startIndex: startIdx);
      if (proj.aheadMeters >= -100) {
        if (nextGas == null || proj.aheadMeters < nextGas) {
          nextGas = proj.aheadMeters;
        }
      }
    }
    // Within ~1 km of a station → re-arm so the NEXT gap warns again.
    if (nextGas != null && nextGas < 1000) {
      _fuelWarned = false;
      return;
    }
    final far = nextGas == null || nextGas > 30000; // >30 km to next fuel
    if (!far || _fuelWarned) return;
    _fuelWarned = true;
    final km = nextGas == null ? null : (nextGas / 1000).round();
    final title = km == null
        ? '⛽ Không thấy trạm xăng phía trước'
        : '⛽ Chuẩn bị đổ xăng';
    final body = km == null
        ? 'Quãng đường phía trước không có trạm xăng. Hãy đổ xăng sớm.'
        : 'Trạm xăng tiếp theo còn khoảng $km km. Hãy chuẩn bị đổ xăng.';
    unawaited(NavForegroundService.instance.notifyFuelWarning(title, body));
    debugPrint('FUEL: gap ahead next=$km km — notified');
  }

  /// "Điều hướng bằng Google Maps": hand off to the installed Google Maps app
  /// (turn-by-turn with Google's roads + live traffic) via a `google.navigation`
  /// deep link. Legitimate + free — NavBridge stays primary for the E-ink
  /// clock / overlay / voice.
  Future<void> _openGoogleMapsNav() async {
    final dest = _destination ?? (_stops.isEmpty ? null : _stops.last.pos);
    final origin = _current ?? _origin;
    if (dest == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Chưa có điểm đến để mở Google Maps.')),
        );
      return;
    }
    final u = Uri.parse(
      'google.navigation:q=${dest.latitude},${dest.longitude}&mode=d'
      '${origin != null ? '&origin=${origin.latitude},${origin.longitude}' : ''}'
      '&language=vi',
    );
    final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Không mở được Google Maps (chưa cài đặt?).'),
          ),
        );
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

  /// A POI was tapped DIRECTLY on the navigation map: select it (the camera
  /// centers on it via the vector map's follow-pause) and ensure the bottom
  /// card shows the "Đi đến" action so the driver can navigate there.
  void _onNavPoiTap(PoiResult p) {
    setNavState(() {
      if (!_pois.any((x) => identical(x, p))) _pois = [p, ..._pois];
      _selectedPoi = p;
    });
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
        preference: _routePreference,
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
        _engine = TurnByTurnEngine(
          route,
          stopNames: _engineStopNames(route),
          maxSpeedMps: _routeProfile.legalMaxMps,
        );
        _alternativeRoutes = routes.length > 1 ? routes : [];
        _selectedRoute = 0;
        _planPoints = points;
        _pois = [];
        _poiType = null;
        _selectedPoi = null;
      });
      unawaited(_loadElevation(route));
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
