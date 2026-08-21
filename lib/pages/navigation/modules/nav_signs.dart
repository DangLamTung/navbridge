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
    // Dedupe: only speak once per sign, and re-speak only if it's the next
    // one (bucket by distance so a noisy fix doesn't re-trigger).
    final bucket = (m ~/ 25) * 25;
    final sig =
        '${next.kind.key}/${next.lat.toStringAsFixed(5)},'
        '${next.lng.toStringAsFixed(5)}/$bucket';
    if (sig == _lastSignSig) return;
    _lastSignSig = sig;
    final phrase = switch (next.kind) {
      RoadSignKind.stop => 'Biển STOP phía trước ${m.round()} mét',
      RoadSignKind.giveWay => 'Biển nhường đường phía trước ${m.round()} mét',
      RoadSignKind.noPassing => 'Cấm vượt phía trước ${m.round()} mét',
      RoadSignKind.noLeftTurn => 'Cấm rẽ trái phía trước ${m.round()} mét',
      RoadSignKind.noRightTurn => 'Cấm rẽ phải phía trước ${m.round()} mét',
      RoadSignKind.noUTurn => 'Cấm quay đầu phía trước ${m.round()} mét',
      RoadSignKind.noLeftUTurn =>
        'Cấm rẽ trái và quay đầu phía trước ${m.round()} mét',
      _ => 'Cấm rẽ phải và quay đầu phía trước ${m.round()} mét',
    };
    _voice.speak(phrase);
    if (mounted) setNavState(() {});
  }

  /// Refresh the nav-map sign layer: signs within a corridor around the
  /// route polyline. Runs in a background isolate (see [signsNearRoute]).
  ///
  /// The way-derived speed signs can be DENSE (28k across VN), so same-value
  /// speed signs within ~330 m are deduped and the total is capped — the map
  /// shows one speed sign per segment, not a wall of 40px icons.
  Future<void> _refreshRouteSigns() async {
    final r = _route;
    if (r == null || r.geometry.length < 2) {
      if (mounted && _routeSigns.isNotEmpty) {
        setNavState(() => _routeSigns = []);
      }
      return;
    }
    final signs = await signsNearRoute(r.geometry, corridorMeters: 250);
    if (!mounted) return;
    const maxShown = 60;
    final kept = <RoadSign>[];
    final speedBuckets = <String>{};
    for (final s in signs) {
      if (s.kind == RoadSignKind.speed) {
        // ~0.003° ≈ 330 m bucket → one speed sign per segment per value.
        final bucket =
            '${s.value}/${(s.lat / 0.003).round()},${(s.lng / 0.003).round()}';
        if (!speedBuckets.add(bucket)) continue;
      }
      kept.add(s);
      if (kept.length >= maxShown) break;
    }
    setNavState(() => _routeSigns = kept);
  }
}
