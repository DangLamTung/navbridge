part of '../navigation_page.dart';

/// Interactive route editing on the preview map: long-press to insert a via
/// point, elevation loading, and the route criteria toggles (avoid highway /
/// ferry).
extension _NavRouteEdit on _NavigationPageState {
  /// Long-press the map to insert a via point and re-plan (interactive
  /// route editing on the OSM/offline map). Resolves a real road/place name
  /// asynchronously via [reverseGeocode].
  void _addViaPoint(LatLng pos) {
    final stops = List<TripStop>.of(_stops);
    final insertIdx = stops.isNotEmpty ? stops.length - 1 : 0;
    stops.insert(
      insertIdx,
      TripStop(name: 'Điểm dừng...', lat: pos.latitude, lng: pos.longitude),
    );
    setNavState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();

    reverseGeocode(pos).then((addr) {
      if (!mounted) return;
      final idx = _stops.indexWhere(
        (s) => s.lat == pos.latitude && s.lng == pos.longitude,
      );
      if (idx >= 0) {
        setNavState(() {
          _stops[idx] = TripStop(
            name: addr,
            lat: pos.latitude,
            lng: pos.longitude,
          );
        });
      }
    });
  }

  /// Min distance (metres) from [p] to the polyline — TRUE perpendicular
  /// distance to each segment (not just to the vertices), so tapping a long
  /// straight segment in the middle still selects the alternative route.
  double _distToLine(LatLng p, List<LatLng> poly) {
    if (poly.isEmpty) return double.infinity;
    if (poly.length == 1) return distanceMeters(p, poly.first);
    var best = double.infinity;
    for (var i = 0; i < poly.length - 1; i++) {
      final a = poly[i];
      final b = poly[i + 1];
      // Local east/north metre frame centred at `a` (flat approx — fine for
      // sub-km segments).
      final cosLat = cos(a.latitude * pi / 180);
      final bx = (b.longitude - a.longitude) * 111320 * cosLat;
      final by = (b.latitude - a.latitude) * 111320;
      final px = (p.longitude - a.longitude) * 111320 * cosLat;
      final py = (p.latitude - a.latitude) * 111320;
      final len2 = bx * bx + by * by;
      if (len2 < 1e-6) {
        // Degenerate segment — fall back to the endpoint distance.
        final dd = distanceMeters(p, a);
        if (dd < best) best = dd;
        continue;
      }
      var t = (px * bx + py * by) / len2;
      t = t.clamp(0.0, 1.0);
      final ex = px - t * bx;
      final ey = py - t * by;
      final d = sqrt(ex * ex + ey * ey);
      if (d < best) best = d;
    }
    return best;
  }

  /// Best-effort elevation (ascent/descent) for the route card, cached per
  /// route. Never fatal — shows nothing when it can't be fetched.
  Future<void> _loadElevation(OsrmRoute route) async {
    final key = '${route.distance.round()}:${route.geometry.length}';
    final cached = _elevationCache[key];
    if (cached != null) {
      if (mounted) setNavState(() => _elevation = cached);
      return;
    }
    final e = await fetchRouteElevation(route.geometry);
    if (e != null) _elevationCache[key] = e;
    debugPrint(
      'ELEV: route ${route.distance.round()}m → '
      '${e == null ? 'no data' : 'up=${e.up.round()} down=${e.down.round()} pts=${e.profile.length}'}',
    );
    if (mounted) setNavState(() => _elevation = e);
  }

  /// Re-plan avoiding motorways (traffic/road-type criteria).
  void _toggleAvoidHighway() {
    setNavState(() => _avoidHighway = !_avoidHighway);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }

  /// Re-plan avoiding ferries.
  void _toggleAvoidFerry() {
    setNavState(() => _avoidFerry = !_avoidFerry);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }
}
