part of 'navigation_page.dart';

/// Opening other screens from the nav page: the trip log (history) and the
/// offline/config hub.
extension _NavScreens on _NavigationPageState {
  Future<void> _openTrips() async {
    final plan = await Navigator.of(
      context,
    ).push<TripPlan>(MaterialPageRoute(builder: (_) => const TripsScreen()));
    if (plan != null && mounted) {
      setNavState(() {
        _stops
          ..clear()
          ..addAll(plan.stops);
        _destination = plan.stops.isEmpty ? null : plan.stops.last.pos;
      });
      _buildPlanRoute();
    }
  }

  Future<void> _openOffline() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const OfflineScreen()));
    // The user may have changed the data source — reload it.
    if (!mounted) return;
    final s = await loadSettings();
    dataSource = s.dataSource;
    setNavState(() {});
  }
}
