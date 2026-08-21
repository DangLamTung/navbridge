part of '../navigation_page.dart';

/// Interactive route editing on the preview map: long-press to insert a via
/// point, elevation loading, and the route criteria toggles (avoid highway /
/// ferry).
extension _NavRouteEdit on _NavigationPageState {
  /// Long-press the map to insert a via point and re-plan (interactive
  /// route editing on the OSM/offline map).
  void _addViaPoint(LatLng pos) {
    final stops = List<TripStop>.of(_stops);
    if (stops.isNotEmpty) {
      stops.insert(
        stops.length - 1,
        TripStop(name: 'Điểm giữa', lat: pos.latitude, lng: pos.longitude),
      );
    }
    setNavState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();
  }

  /// Min distance (meters) from [p] to a polyline — used to make the
  /// alternative route lines tappable.
  double _distToLine(LatLng p, List<LatLng> poly) {
    if (poly.isEmpty) return double.infinity;
    var best = distanceMeters(p, poly.first);
    for (var i = 1; i < poly.length; i++) {
      final d = distanceMeters(p, poly[i]);
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
