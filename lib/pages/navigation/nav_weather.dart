part of 'navigation_page.dart';

/// Weather for the bottom status bar (Open-Meteo, refreshed every 10 min on a
/// background async call so it never blocks the UI).
extension _NavWeather on _NavigationPageState {
  /// Start refreshing the current weather (Open-Meteo) for the bottom status
  /// bar while navigating; refreshed every 10 minutes. The fetch runs on a
  /// background (async) call so it never blocks the UI.
  void _startWeather() {
    _stopWeather();
    _refreshWeather();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _refreshWeather(),
    );
  }

  void _stopWeather() {
    _weatherTimer?.cancel();
    _weatherTimer = null;
  }

  Future<void> _refreshWeather() async {
    final cur = _current ?? _origin;
    if (cur == null) return;
    final w = await fetchWeather(cur.latitude, cur.longitude);
    if (mounted && w != null) setNavState(() => _weather = w);
  }
}
