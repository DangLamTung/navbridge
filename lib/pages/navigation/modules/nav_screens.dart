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
    dataSource = s.dataSource;
    setNavState(() {});
  }
}
