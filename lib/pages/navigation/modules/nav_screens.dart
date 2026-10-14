part of '../navigation_page.dart';

/// Opening other screens from the nav page: the settings hub.
extension _NavScreens on _NavigationPageState {
  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    // The user may have changed the data source — reload it.
    if (!mounted) return;
    final s = await loadSettings();
    // And the sim-arm overrides are done with: whatever the settings screen now
    // holds is the user's explicit choice (see `_voiceOverride`).
    _voiceOverride = null;
    _phoneHeadingOverride = null;
    dataSource = s.dataSource;
    vehicleType = s.vehicleType;
    _routeProfile = switch (s.vehicleType) {
      'motorbike' => RouteProfile.motorbike,
      _ => RouteProfile.car,
    };
    // The basemap layer is persisted too, so a change made in Settings (or on an
    // earlier run) has to reach the live map here.
    _setTileSource(s.basemapLayer, persist: false);
    setNavState(() {});
  }
}
