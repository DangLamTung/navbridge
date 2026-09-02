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
    // effect within ~400 m — nothing changes too early.
    final ahead = await signsAheadOnRoute(
      snapped,
      geometry,
      maxAheadMeters: 1000,
    );
    if (!mounted) return;
    // Speed-limit signs (incl. the Waze speed data copied onto each road
    // segment) set the EFFECTIVE limit: as the car approaches the next
    // speed-limit sign it becomes the current limit (~400 m out), so the
    // overspeed alert and the speed chip preview the segment you're entering.
    for (final a in ahead) {
      if (a.sign.kind == RoadSignKind.speed && a.sign.value != null) {
        if (a.routeMeters <= 400 && a.sign.value != _signSpeedLimit) {
          _signSpeedLimit = a.sign.value;
          if (mounted) setNavState(() {});
        }
        break;
      }
    }
    // ADVANCE warning: a LOWER speed limit is coming up (400–1000 m) — say it
    // once per sign so the driver can slow down BEFORE the sign, not after.
    // A higher limit ahead needs no warning (the normal "Giới hạn X" fires
    // when it takes effect).
    if (_voiceOn && _voice.ready) {
      for (final a in ahead) {
        final k = a.sign.kind;
        final v = a.sign.value;
        // Skip non-speed signs — a nearer STOP/give-way sign must NOT block
        // the speed-drop warning for a speed sign further ahead.
        if (k != RoadSignKind.speed || v == null || v <= 0) continue;
        final cur = _effectiveSpeedLimit;
        if (a.routeMeters > 400 &&
            a.routeMeters <= 1000 &&
            cur > 0 &&
            v < cur) {
          final sig =
              'spd-${a.sign.lat.toStringAsFixed(5)},'
              '${a.sign.lng.toStringAsFixed(5)}';
          if (!_speedChangeDedupe.seen(sig)) {
            _voice.speak(
              'Giảm tốc độ, giới hạn $v km/h phía trước '
              '${formatDistanceSpoken(a.routeMeters)}',
              priority: VoiceGuide.priorityHigh,
            );
          }
        }
        break; // only the NEAREST speed sign matters
      }
    }
    // Populated-area boundary: entering "khu đông dân cư" drops the limit to
    // the VN statutory built-up limit (motorbike 40 / car 50 / truck 40 km/h —
    // QCVN 41); leaving clears it back to the road default. `ahead` is
    // ordered by distance, so the first boundary sign is the one we are about
    // to cross. The boundary is ALSO announced once per crossing ("Vào khu
    // đông dân cư, giới hạn X") so the driver knows WHY the limit just
    // dropped — this was the residential content the old camera flattening
    // hid.
    //
    // Thông tư 38/2024/TT-BGTVT (hiệu lực 01/01/2025) — trong khu đông dân cư,
    // đường hai chiều / 1 làn: xe mô tô = 50, xe con = 50, xe tải = 40 km/h.
    // (40 is the xe GẮN MÁY / moped limit — the app's 'motorbike' mode is xe
    // mô tô, so it must be 50. This now matches statutoryLimit('residential',
    // vehicle:'motorbike') = 50; previously it wrongly dropped to 40.)
    final zoneLimit = switch (vehicleType) {
      'car' => 50,
      'motorbike' => 50,
      'truck' => 40,
      _ => 50,
    };
    for (final a in ahead) {
      if (a.routeMeters > 400) break; // apply the boundary only when close
      final k = a.sign.kind;
      if (k == RoadSignKind.populated) {
        if (_zoneSpeedLimit != zoneLimit) {
          _zoneSpeedLimit = zoneLimit;
          if (mounted) setNavState(() {});
          if (_voiceOn) {
            _voice.speak('Vào khu đông dân cư, giới hạn $zoneLimit km/h');
          }
        }
        break;
      }
      if (k == RoadSignKind.populatedEnd) {
        if (_zoneSpeedLimit != null) {
          _zoneSpeedLimit = null;
          if (mounted) setNavState(() {});
          if (_voiceOn) {
            _voice.speak('Hết khu đông dân cư');
          }
        }
        break;
      }
    }
    // Nearest sign ahead that we ANNOUNCE: STOP, give-way, the VN prohibitions
    // drivers must slow for (cấm vượt / cấm rẽ / cấm quay đầu), and traffic
    // lights. Speed + "đông dân cư" signs are map-only.
    if (!_voiceOn) return;
    RoadSign? next;
    var m = 0.0;
    for (final a in ahead) {
      if (a.routeMeters > 400) break; // only announce signs within ~400 m
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
          k == RoadSignKind.onlyStraight ||
          k == RoadSignKind.onlyLeft ||
          k == RoadSignKind.onlyRight ||
          k == RoadSignKind.endProhibitions ||
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
    _voice.speak(phrase);
    if (mounted) setNavState(() {});
  }
}
