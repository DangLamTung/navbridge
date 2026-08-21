part of '../navigation_page.dart';

/// RAIN RADAR — a live rain map over the basemap (RainViewer, free/no key).
/// The toggle is persisted ([AppSettings.radar]); frames are cached ~5 min
/// and shown as a compact selector so the driver can watch the storm move
/// (past frames) or jump to the nowcast forecast when it's live.
extension _NavRadar on _NavigationPageState {
  /// Chronological frames: a compact set of past frames (≈ -20 min steps,
  /// capped at 6) followed by up to 4 nowcast (forecast) frames when live.
  List<RadarFrame> get _radarFrames {
    final d = _radar;
    if (d == null) return const [];
    final recent = <RadarFrame>[];
    for (var i = d.past.length - 1; i >= 0 && recent.length < 6; i -= 2) {
      recent.add(d.past[i]);
    }
    return [...recent.reversed, ...d.nowcast.take(4)];
  }

  /// URL template for the currently selected radar frame (or null when the
  /// radar isn't loaded).
  String? get _radarLayerUrl {
    final d = _radar;
    if (d == null) return null;
    final frames = _radarFrames;
    if (frames.isEmpty) return null;
    final i = _radarFrame.clamp(0, frames.length - 1);
    return radarTileUrl(d, frames[i]);
  }

  Future<void> _toggleRadar() async {
    setNavState(() => radarOn = !radarOn);
    if (radarOn) {
      await _ensureRadar();
    }
    _persistRadar();
  }

  /// Re-fetch the radar frame index (cached ~5 min) so the overlay stays
  /// current. Best-effort — failure shows a snackbar and leaves the overlay
  /// off (or showing the last-known frames).
  Future<void> _ensureRadar() async {
    final d = _radar;
    if (d != null &&
        _radarFetchedAt != null &&
        DateTime.now().difference(_radarFetchedAt!) <
            const Duration(minutes: 5)) {
      return;
    }
    setNavState(() => _radarLoading = true);
    final r = await fetchRadarData();
    if (!mounted) return;
    setNavState(() {
      _radarLoading = false;
      if (r != null && r.hasFrames) {
        _radar = r;
        _radarFetchedAt = DateTime.now();
        _radarFrame = 0;
      }
    });
    if (r == null || !r.hasFrames) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Không tải được radar thời tiết.')),
        );
    }
  }

  void _setRadarFrame(int i) {
    if (i < 0 || i >= _radarFrames.length) return;
    setNavState(() => _radarFrame = i);
  }

  void _persistRadar() {
    loadSettings().then(
      (s) => saveSettings(
        AppSettings(
          forceOffline: s.forceOffline,
          dataSource: s.dataSource,
          vehicleType: s.vehicleType,
          geocodingProvider: s.geocodingProvider,
          routingEngine: s.routingEngine,
          smoothCamera: s.smoothCamera,
          cameraAlerts: s.cameraAlerts,
          radar: radarOn,
          pipAspect: s.pipAspect,
          ridingMode: s.ridingMode,
          simpleMode: s.simpleMode,
          wakeWord: s.wakeWord,
        ),
      ),
    );
  }
}
