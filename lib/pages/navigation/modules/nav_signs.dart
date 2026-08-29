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
    if (!_signGate.tryOpen()) return;
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
    // Populated-area boundary: entering "khu đông dân cư" drops the limit to
    // 40 km/h (built-up area, VN); leaving clears it back to the road default.
    // `ahead` is ordered by distance, so the first boundary sign is the one
    // we are about to cross.
    for (final a in ahead) {
      final k = a.sign.kind;
      if (k == RoadSignKind.populated) {
        if (_zoneSpeedLimit != 40) {
          _zoneSpeedLimit = 40;
          if (mounted) setNavState(() {});
        }
        break;
      }
      if (k == RoadSignKind.populatedEnd) {
        if (_zoneSpeedLimit != null) {
          _zoneSpeedLimit = null;
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
    if (_signDedupe.seen(sig)) return;
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
}
