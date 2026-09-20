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
    // Look ~1 km ahead so a speed-limit DROP can be warned about BEFORE the
    // driver reaches it, while the limit itself (chip / overspeed) only takes
    // effect within [kSignAdoptM] — nothing changes too early.
    final ahead = await signsAheadOnRoute(
      snapped,
      geometry,
      maxAheadMeters: kSignWarnM,
    );
    if (!mounted) return;
    // Speed-limit signs (incl. the Waze speed data copied onto each road
    // segment) set the EFFECTIVE limit — but only once the car REACHES them:
    // while one is merely ahead (`routeMeters` up to [kSignAdoptM]) it is a
    // preview, used for the "tiếp theo" wording and the drop-ahead warning
    // below. See [signLimitInForce] for why applying it early is wrong.
    for (final a in ahead) {
      if (a.sign.kind == RoadSignKind.speed && a.sign.value != null) {
        if (a.routeMeters <= kSignAdoptM) {
          _signAheadM = a.routeMeters; // >kSignReachedM ⇒ preview only
          if (a.sign.value != _signSpeedLimit) {
            _signSpeedLimit = a.sign.value;
            _signSpeedLimitRoad = _roadInfo?.name;
            if (mounted) setNavState(() {});
          }
        }
        break;
      }
    }
    // Bind a held sign to the road it stands on as soon as that road is KNOWN.
    // A sign adopted before the first road lookup left `_signSpeedLimitRoad`
    // null, and `signLimitInForce` reads a missing road as "trusted" — so
    // without this the value could outlive every road change for the rest of
    // the drive.
    if (_signSpeedLimit != null &&
        _signAheadM <= kSignReachedM &&
        (_signSpeedLimitRoad == null || _signSpeedLimitRoad!.isEmpty)) {
      final name = _roadInfo?.name;
      if (name != null && name.isNotEmpty) _signSpeedLimitRoad = name;
    }
    // The nearest speed sign is already behind the car (or further than the
    // [kSignAdoptM] adoption window) → whatever limit we hold is now IN FORCE.
    if (!ahead.any(
      (a) =>
          a.sign.kind == RoadSignKind.speed &&
          a.sign.value != null &&
          a.routeMeters <= kSignAdoptM,
    )) {
      _signAheadM = 0;
    }
    // ADVANCE warning: a LOWER speed limit is coming up ([kSignAdoptM]..
    // [kSignWarnM]) — say it once per sign so the driver can slow down BEFORE
    // the sign, not after. A higher limit ahead needs no warning (the normal
    // "Giới hạn X" fires when it takes effect).
    if (_voiceOn && _voice.ready) {
      for (final a in ahead) {
        final k = a.sign.kind;
        final v = a.sign.value;
        // Skip non-speed signs — a nearer STOP/give-way sign must NOT block
        // the speed-drop warning for a speed sign further ahead.
        if (k != RoadSignKind.speed || v == null || v <= 0) continue;
        final cur = _effectiveSpeedLimit;
        if (a.routeMeters > kSignAdoptM &&
            a.routeMeters <= kSignWarnM &&
            cur > 0 &&
            v < cur) {
          final sig =
              'spd-${a.sign.lat.toStringAsFixed(5)},'
              '${a.sign.lng.toStringAsFixed(5)}';
          if (!_speedChangeDedupe.seen(sig)) {
            final spdTxt =
                'Giảm tốc độ, giới hạn $v km/h phía trước '
                '${formatDistanceSpoken(a.routeMeters)}';
            _logAnnouncement(spdTxt, kind: 'sign');
            _voice.speak(spdTxt, priority: VoiceGuide.priorityHigh);
          }
        }
        break; // only the NEAREST speed sign matters
      }
    }
    // The "bắt đầu / hết khu đông dân cư" boundary used to set a built-up zone
    // flag here, which capped the speed limit for the rest of the drive.
    // REMOVED: 9,211 points (20.4% of the sign DB) bought a limit source that
    // never fired on a recorded drive (0 boundary points within 200 m of any of
    // the 38 recorded tracks) and that overrides a posted segment value 39% of
    // the time it does land on one. The limit is now posted signs + the road's
    // own class value only — see [droppedSignKinds] in offline_road_signs.dart.
    //
    // Nearest sign ahead that we ANNOUNCE: STOP, give-way, the VN prohibitions
    // drivers must slow for (cấm vượt / cấm rẽ / cấm quay đầu), and traffic
    // lights. Speed signs are map-only.
    if (!_voiceOn) return;
    RoadSign? next;
    var m = 0.0;
    for (final a in ahead) {
      // Only announce signs inside the adoption window.
      if (a.routeMeters > kSignAdoptM) break;
      final k = a.sign.kind;
      if (k == RoadSignKind.stop ||
          k == RoadSignKind.giveWay ||
          k == RoadSignKind.noPassing ||
          k == RoadSignKind.noPassingEnd ||
          k == RoadSignKind.noLeftTurn ||
          k == RoadSignKind.noRightTurn ||
          k == RoadSignKind.noUTurn ||
          k == RoadSignKind.noLeftUTurn ||
          k == RoadSignKind.noRightUTurn ||
          k == RoadSignKind.noAuto ||
          k == RoadSignKind.noMoto ||
          k == RoadSignKind.noParking ||
          k == RoadSignKind.noStraight ||
          k == RoadSignKind.noTurnBoth ||
          k == RoadSignKind.onlyStraight ||
          k == RoadSignKind.onlyLeft ||
          k == RoadSignKind.onlyRight ||
          k == RoadSignKind.endProhibitions ||
          k == RoadSignKind.oneWay ||
          k == RoadSignKind.reservedLane ||
          k == RoadSignKind.signal) {
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
    // Traffic lights are announced ONLY when near (~100 m) — the colour is
    // unknown, so a far "đèn giao thông" is noise and the driver sees it
    // coming anyway.
    if (next.kind == RoadSignKind.signal && !near) return;
    final zone = near ? 'near' : 'far';
    final sig =
        '${next.kind.key}/${next.lat.toStringAsFixed(5)},'
        '${next.lng.toStringAsFixed(5)}/$zone';
    if (_signDedupe.seen(sig)) return;
    final phrase = switch (next.kind) {
      RoadSignKind.stop =>
        near
            ? 'Biển STOP sắp tới'
            : 'Biển STOP phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.giveWay =>
        near
            ? 'Biển nhường đường sắp tới'
            : 'Biển nhường đường phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noPassing =>
        near
            ? 'Cấm vượt sắp tới'
            : 'Cấm vượt phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noLeftTurn =>
        near
            ? 'Cấm rẽ trái sắp tới'
            : 'Cấm rẽ trái phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noRightTurn =>
        near
            ? 'Cấm rẽ phải sắp tới'
            : 'Cấm rẽ phải phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noUTurn =>
        near
            ? 'Cấm quay đầu sắp tới'
            : 'Cấm quay đầu phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noLeftUTurn =>
        near
            ? 'Cấm rẽ trái và quay đầu sắp tới'
            : 'Cấm rẽ trái và quay đầu phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noRightUTurn =>
        near
            ? 'Cấm rẽ phải và quay đầu sắp tới'
            : 'Cấm rẽ phải và quay đầu phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noPassingEnd =>
        near
            ? 'Hết cấm vượt sắp tới'
            : 'Hết cấm vượt phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.onlyStraight =>
        near
            ? 'Chỉ đi thẳng sắp tới'
            : 'Chỉ được đi thẳng phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.onlyRight =>
        near
            ? 'Chỉ rẽ phải sắp tới'
            : 'Chỉ được rẽ phải phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.onlyLeft =>
        near
            ? 'Chỉ rẽ trái sắp tới'
            : 'Chỉ được rẽ trái phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.endProhibitions =>
        near
            ? 'Hết mọi lệnh cấm sắp tới'
            : 'Hết mọi lệnh cấm phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.slowDown =>
        near
            ? 'Giảm tốc độ sắp tới'
            : 'Giảm tốc độ phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.tollBooth =>
        near
            ? 'Trạm thu phí sắp tới'
            : 'Trạm thu phí phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.railwayCrossing =>
        near
            ? 'Đường ngang giao với đường sắt sắp tới'
            : 'Đường ngang giao với đường sắt phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.tunnel =>
        near
            ? 'Hầm đường bộ sắp tới'
            : 'Hầm đường bộ phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noAuto =>
        near
            ? 'Cấm ô tô sắp tới'
            : 'Cấm ô tô phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noMoto =>
        near
            ? 'Cấm xe máy sắp tới'
            : 'Cấm xe máy phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noParking =>
        near
            ? 'Cấm đỗ xe sắp tới'
            : 'Cấm đỗ xe phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noStraight =>
        near
            ? 'Cấm đi thẳng sắp tới'
            : 'Cấm đi thẳng phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.noTurnBoth =>
        near
            ? 'Cấm rẽ trái và rẽ phải sắp tới'
            : 'Cấm rẽ trái và rẽ phải phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.oneWay =>
        near
            ? 'Đường một chiều sắp tới'
            : 'Đường một chiều phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.reservedLane =>
        near
            ? 'Làn dành riêng sắp tới'
            : 'Làn dành riêng phía trước ${formatDistanceSpoken(m)}',
      RoadSignKind.signal =>
        // Near-only (see above), so the `near` branch is the one used.
        near
            ? 'Đèn giao thông sắp tới'
            : 'Đèn giao thông phía trước ${formatDistanceSpoken(m)}',
      _ =>
        near
            ? 'Cấm rẽ phải và quay đầu sắp tới'
            : 'Cấm rẽ phải và quay đầu phía trước ${formatDistanceSpoken(m)}',
    };
    _logAnnouncement(phrase, kind: 'sign');
    _voice.speak(phrase);
    if (mounted) setNavState(() {});
  }
}
