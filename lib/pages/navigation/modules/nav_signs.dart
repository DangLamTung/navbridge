part of '../navigation_page.dart';

/// ROAD SIGNS — stop / give-way / traffic-light data from the bundled
/// Vietnam index ([offline_road_signs.dart]). During navigation:
///  - STOP + give-way signs are ANNOUNCED when they're ahead on the route
///    (unconditional — unlike traffic lights, whose colour isn't known, so
///    announcing "đèn đỏ" when it's green would be misleading).
///  - All three kinds are shown on the nav map (colored dots near the route).
extension _NavSigns on _NavigationPageState {
  /// Per-GPS-fix check (throttled ~1 s): find the next stop/give-way sign
  /// ahead on the route and speak it when within ~400 m.
  void _checkSignAhead(LatLng snapped, List<LatLng> geometry) {
    final now = DateTime.now();
    if (_lastSignCheck != null &&
        now.difference(_lastSignCheck!) < const Duration(seconds: 1)) {
      return;
    }
    _lastSignCheck = now;
    unawaited(_signAheadAsync(snapped, geometry));
  }

  Future<void> _signAheadAsync(LatLng snapped, List<LatLng> geometry) async {
    final ahead = await signsAheadOnRoute(
      snapped,
      geometry,
      maxAheadMeters: 400,
    );
    if (!mounted) return;
    // Speed-limit signs (incl. the Waze speed data copied onto each road
    // segment) set the EFFECTIVE limit: as the car approaches the next
    // speed-limit sign it becomes the current limit, so the overspeed alert
    // and the speed chip preview the segment you're entering.
    for (final a in ahead) {
      if (a.sign.kind == RoadSignKind.speed && a.sign.value != null) {
        if (a.sign.value != _signSpeedLimit) {
          _signSpeedLimit = a.sign.value;
          if (mounted) setNavState(() {});
        }
        break;
      }
    }
    // Nearest sign ahead that we ANNOUNCE: STOP, give-way, and the VN
    // prohibitions drivers must slow for (cấm vượt / cấm rẽ / cấm quay đầu).
    // Speed, "đông dân cư" and traffic-light signs are map-only.
    if (!_voiceOn) return;
    RoadSign? next;
    var m = 0.0;
    for (final a in ahead) {
      final k = a.sign.kind;
      if (k == RoadSignKind.stop ||
          k == RoadSignKind.giveWay ||
          k == RoadSignKind.noPassing ||
          k == RoadSignKind.noLeftTurn ||
          k == RoadSignKind.noRightTurn ||
          k == RoadSignKind.noUTurn ||
          k == RoadSignKind.noLeftUTurn ||
          k == RoadSignKind.noRightUTurn) {
        next = a.sign;
        m = a.routeMeters;
        break;
      }
    }
    if (next == null) return;
    // Announce at most TWICE per sign: once far (the first time it enters the
    // 400 m range) and once near (~100 m) as the final reminder. The old
    // per-25 m bucket re-spoke every ~25 m, which nagged the driver.
    final near = m <= 100;
    final zone = near ? 'near' : 'far';
    final sig =
        '${next.kind.key}/${next.lat.toStringAsFixed(5)},'
        '${next.lng.toStringAsFixed(5)}/$zone';
    if (sig == _lastSignSig) return;
    _lastSignSig = sig;
    final phrase = switch (next.kind) {
      RoadSignKind.stop =>
        near ? 'Biển STOP sắp tới' : 'Biển STOP phía trước ${m.round()} mét',
      RoadSignKind.giveWay =>
        near
            ? 'Biển nhường đường sắp tới'
            : 'Biển nhường đường phía trước ${m.round()} mét',
      RoadSignKind.noPassing =>
        near ? 'Cấm vượt sắp tới' : 'Cấm vượt phía trước ${m.round()} mét',
      RoadSignKind.noLeftTurn =>
        near
            ? 'Cấm rẽ trái sắp tới'
            : 'Cấm rẽ trái phía trước ${m.round()} mét',
      RoadSignKind.noRightTurn =>
        near
            ? 'Cấm rẽ phải sắp tới'
            : 'Cấm rẽ phải phía trước ${m.round()} mét',
      RoadSignKind.noUTurn =>
        near
            ? 'Cấm quay đầu sắp tới'
            : 'Cấm quay đầu phía trước ${m.round()} mét',
      RoadSignKind.noLeftUTurn =>
        near
            ? 'Cấm rẽ trái và quay đầu sắp tới'
            : 'Cấm rẽ trái và quay đầu phía trước ${m.round()} mét',
      _ =>
        near
            ? 'Cấm rẽ phải và quay đầu sắp tới'
            : 'Cấm rẽ phải và quay đầu phía trước ${m.round()} mét',
    };
    _voice.speak(phrase);
    if (mounted) setNavState(() {});
  }

  /// Refresh the nav-map sign layer: signs within a corridor around the
  /// route polyline. Runs in a background isolate (see [signsNearRoute]).
  ///
  /// The way-derived speed signs can be DENSE (28k across VN), so same-value
  /// speed signs within ~330 m are deduped and the total is capped — the map
  /// shows one speed sign per segment, not a wall of 40px icons. Traffic
  /// lights are also deduped (~130 m) and ranked LAST so a dense city
  /// corridor can't crowd out the STOP / give-way / speed / prohibition
  /// signs a driver actually needs.
  Future<void> _refreshRouteSigns() async {
    final r = _route;
    if (r == null || r.geometry.length < 2) {
      if (mounted && _routeSigns.isNotEmpty) {
        setNavState(() => _routeSigns = []);
      }
      return;
    }
    // Visualize signs within 500 m of the main route (was 250 m).
    final signs = await signsNearRoute(r.geometry, corridorMeters: 500);
    if (!mounted) return;
    const maxShown = 80;
    final kept = <RoadSign>[];
    final speedBuckets = <String>{};
    final signalBuckets = <String>{};
    // Warning signs first, traffic lights last (stable sort keeps the rest).
    final ranked = [...signs]
      ..sort((a, b) {
        final pa = a.kind == RoadSignKind.signal ? 1 : 0;
        final pb = b.kind == RoadSignKind.signal ? 1 : 0;
        return pa.compareTo(pb);
      });
    for (final s in ranked) {
      if (s.kind == RoadSignKind.speed) {
        // ~0.003° ≈ 330 m bucket → one speed sign per segment per value.
        final bucket =
            '${s.value}/${(s.lat / 0.003).round()},${(s.lng / 0.003).round()}';
        if (!speedBuckets.add(bucket)) continue;
      } else if (s.kind == RoadSignKind.signal) {
        // ~0.0012° ≈ 130 m bucket → one traffic-light icon per junction.
        final bucket =
            '${(s.lat / 0.0012).round()},${(s.lng / 0.0012).round()}';
        if (!signalBuckets.add(bucket)) continue;
      }
      kept.add(s);
      if (kept.length >= maxShown) break;
    }
    setNavState(() => _routeSigns = kept);
  }
}
