part of '../navigation_page.dart';

/// ROAD SIGNS — stop / give-way / traffic-light data from the bundled
/// Vietnam index ([offline_road_signs.dart]). During navigation:
///  - STOP + give-way signs are ANNOUNCED when they're ahead on the route
///    (unconditional — unlike traffic lights, whose colour isn't known, so
///    announcing "đèn đỏ" when it's green would be misleading).
///  - All three kinds are shown on the nav map (colored dots near the route).
/// Kinds whose callout the voice says at all. Speed signs are map-only, and
/// tunnel / railway-crossing / toll-booth / slow-down are deliberately absent —
/// see [droppedSignKinds] for why the built-up boundary kinds ARE in here.
const Set<RoadSignKind> announcedSignKinds = {
  RoadSignKind.stop,
  RoadSignKind.giveWay,
  RoadSignKind.noPassing,
  RoadSignKind.noPassingEnd,
  RoadSignKind.noLeftTurn,
  RoadSignKind.noRightTurn,
  RoadSignKind.noUTurn,
  RoadSignKind.noLeftUTurn,
  RoadSignKind.noRightUTurn,
  RoadSignKind.noAuto,
  RoadSignKind.noMoto,
  RoadSignKind.noParking,
  RoadSignKind.noStraight,
  RoadSignKind.noTurnBoth,
  RoadSignKind.onlyStraight,
  RoadSignKind.onlyLeft,
  RoadSignKind.onlyRight,
  RoadSignKind.endProhibitions,
  RoadSignKind.oneWay,
  RoadSignKind.reservedLane,
  // Khu đông dân cư boundaries: entering / leaving a built-up area is
  // the one "sign" that applies to the next few kilometres of road, so
  // it is announced like a prohibition (user: "say Bắt đầu khu dân cư /
  // Hết khu dân cư").
  RoadSignKind.populated,
  RoadSignKind.populatedEnd,
  RoadSignKind.signal,
};

/// Announcement TIER for [kind] — LOWER WINS.
///
/// Tier 0 is the built-up boundary. It governs the next few kilometres, so it
/// must not lose the voice to a nearer one-off plate that carries no driving
/// information. Tier 1 is the "obey now or it is dangerous" set (STOP,
/// give-way, the overtaking bans, the traffic light); turn / lane plates are
/// tier 2. Measured cost of the old pure-nearest rule: 27 of 84 built-up zones
/// on the 22-trip batch had no callout within 3 km
/// (`tool/resident_misses.py`).
int signAnnounceTier(RoadSignKind kind) => switch (kind) {
      RoadSignKind.populated || RoadSignKind.populatedEnd => 0,
      RoadSignKind.stop ||
      RoadSignKind.giveWay ||
      RoadSignKind.noPassing ||
      RoadSignKind.noPassingEnd ||
      RoadSignKind.signal =>
        1,
      _ => 2,
    };

/// Dedupe key for a sign callout: kind + the sign's own position + far/near.
/// Pure, so "far then near, and never twice" can be pinned by a test.
String signCalloutSig(RoadSign sign, {required bool near}) =>
    '${sign.kind.key}/${sign.lat.toStringAsFixed(5)},'
    '${sign.lng.toStringAsFixed(5)}/${near ? 'near' : 'far'}';

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
    // 1. Process signs reached within [kSignReachedM] (50 m):
    final reachedSigns = ahead.where((a) => a.routeMeters <= kSignReachedM).toList();
    var reachedTownBoundary = false;

    // Macro-regulatory and zone transitions:
    for (final a in reachedSigns) {
      final k = a.sign.kind;
      if (k == RoadSignKind.endProhibitions) {
        // Sign DP.134 / DP.135: end of speed limit / end of all prohibitions.
        // Reverts explicit speed sign back to the underlying road limit.
        if (_signSpeedLimit != null) {
          _signSpeedLimit = null;
          _signSpeedLimitRoad = null;
          _signAheadM = 0;
          if (mounted) setNavState(() {});
        }
      } else if (k == RoadSignKind.populated) {
        // Sign R.420: Bắt đầu khu đông dân cư
        reachedTownBoundary = true;
        if (!_inTownBySign || !_inTown) {
          _inTown = true;
          _inTownBySign = true;
          _updateRoadForTownChange(true, at: snapped);
          if (mounted) setNavState(() {});
        }
      } else if (k == RoadSignKind.populatedEnd) {
        // Sign R.421: Hết khu đông dân cư
        reachedTownBoundary = true;
        if (!_inTownBySign || _inTown) {
          _inTown = false;
          _inTownBySign = true;
          _updateRoadForTownChange(false, at: snapped);
          if (mounted) setNavState(() {});
        }
      }
    }

    // Explicit speed limit signs reached (P.127):
    final reachedSpeed = reachedSigns.where(
      (a) => a.sign.kind == RoadSignKind.speed && a.sign.value != null,
    ).firstOrNull;

    if (reachedSpeed != null) {
      if (reachedSpeed.sign.value != _signSpeedLimit) {
        _signSpeedLimit = reachedSpeed.sign.value;
        _signSpeedLimitRoad = _roadInfo?.name;
        _signAheadM = 0;
        if (mounted) setNavState(() {});
      }
    } else if (reachedTownBoundary) {
      // Crossing a built-up boundary without an explicit speed sign posted at
      // the boundary terminates any prior open-road / urban sign limit, reverting
      // to the statutory table for the new zone.
      if (_signSpeedLimit != null) {
        _signSpeedLimit = null;
        _signSpeedLimitRoad = null;
        _signAheadM = 0;
        if (mounted) setNavState(() {});
      }
    }

    // Validate active sign continuity:
    if (_signSpeedLimit != null) {
      final curRoad = _roadInfo?.name;
      if (_signSpeedLimitRoad != null &&
          _signSpeedLimitRoad!.isNotEmpty &&
          curRoad != null &&
          curRoad.isNotEmpty &&
          !sameRoad(_signSpeedLimitRoad!, curRoad)) {
        // A speed sign only applies on the road it is posted on; turning onto
        // a different road drops the sign limit.
        _signSpeedLimit = null;
        _signSpeedLimitRoad = null;
        _signAheadM = 0;
        if (mounted) setNavState(() {});
      } else if (_signSpeedLimitRoad == null || _signSpeedLimitRoad!.isEmpty) {
        // Bind road name as soon as it becomes known.
        if (curRoad != null && curRoad.isNotEmpty) {
          _signSpeedLimitRoad = curRoad;
        }
      }
    }

    // ADVANCE warning: a LOWER speed limit is coming up ([kSignReachedM]..
    // [kSignWarnM]) — say it once per sign so the driver can slow down BEFORE
    // the sign, not after. A higher limit ahead needs no warning (the normal
    // "Giới hạn X" fires when it takes effect).
    if (_voiceOn && _voiceReady) {
      for (final a in ahead) {
        final k = a.sign.kind;
        final v = a.sign.value;
        // Skip non-speed signs — a nearer STOP/give-way sign must NOT block
        // the speed-drop warning for a speed sign further ahead.
        if (k != RoadSignKind.speed || v == null || v <= 0) continue;
        final cur = _effectiveSpeedLimit;
        if (a.routeMeters > kSignReachedM &&
            a.routeMeters <= kSignWarnM &&
            cur > 0 &&
            v < cur) {
          final sig =
              'spd-${a.sign.lat.toStringAsFixed(5)},'
              '${a.sign.lng.toStringAsFixed(5)}';
          if (!_speedChangeDedupe.seen(sig)) {
            // The sign's own value, capped for THIS vehicle — the number spoken
            // is always the max that applies to the vehicle, never above the
            // sign (user: "just say 1 for vehicle class").
            final vEff = effectiveLimit(
              '',
              vehicle: vehicleType,
              taggedKmh: v,
              urban: _inTown,
              postedSrc: srcSegment,
            );
            final shown = vEff > 0 ? vEff : v;
            final spdTxt =
                'Tốc độ tối đa $shown km/h phía trước '
                '${formatDistanceSpoken(a.routeMeters)}';
            _logAnnouncement(spdTxt, kind: 'sign');
            _voice.speak(spdTxt, priority: VoiceGuide.priorityHigh);
            _noteLimitSpoken(shown);
          }
        }
        break; // only the NEAREST speed sign matters
      }
    }
    // The "bắt đầu / hết khu đông dân cư" boundary is announced and, once
    // reached on the route, establishes the statutory zone (_inTownBySign = true)
    // for roads with no posted Waze segment layer.
    //
    // Nearest sign ahead that we ANNOUNCE: STOP, give-way, the VN prohibitions
    // drivers must slow for (cấm vượt / cấm rẽ / cấm quay đầu), and traffic
    // lights. Speed signs are map-only.
    if (!_voiceOn) return;
    // WHICH SIGN GETS THE VOICE. The old rule was "the nearest announceable
    // sign wins": it broke out of the loop on the first allowed kind and then
    // `return`ed on the dedupe hit. Two consequences, both measured on the
    // 22-trip batch:
    //
    //   1. STARVATION — a nearer, minor plate (a no-parking sign 20 m away)
    //      was chosen on every fix, its callout was already spent, and the
    //      function returned before a built-up boundary 300 m ahead could ever
    //      be reached. The boundary lost to a plate that carries no driving
    //      information.
    //   2. SIGNAL SWALLOWING — a traffic light inside the 400 m window but
    //      further than 100 m returned early, silencing every sign behind it.
    //
    // Now the window is walked by TIER first and distance second, and a
    // candidate whose callout is already spoken is SKIPPED rather than
    // returned on.
    RoadSign? next;
    var m = 0.0;
    var bestTier = 1 << 30;
    for (final a in ahead) {
      // Only announce signs inside the adoption window.
      if (a.routeMeters > kSignAdoptM) break;
      final k = a.sign.kind;
      if (!announcedSignKinds.contains(k)) continue;
      // Announce at most TWICE per sign: once far (the first time it enters the
      // 400 m range) and once near (~100 m) as the final reminder. The old
      // per-25 m bucket re-spoke every ~25 m, which nagged the driver.
      final near = a.routeMeters <= 100;
      if (k == RoadSignKind.signal) {
        // Traffic lights are announced ONLY when near (~100 m) — the colour is
        // unknown, so a far "đèn giao thông" is noise and the driver sees it
        // coming anyway. SKIP, do not return: a light must not silence a sign
        // behind it.
        if (!near) continue;
        // A traffic light AND a red-light camera at the same junction is ONE
        // hazard: the camera alert already says "Camera đèn đỏ … phía trước"
        // (with distance and, in the tap sheet, its source), so the sign
        // callout would say the same thing twice (user, 2026-09-24: "we have
        // đèn đỏ and đèn giao thông sắp tới which is overlap and not needed").
        // The LIGHT callout is the one dropped — it carries no colour and no
        // source — but only where a red-light camera actually covers the
        // junction; elsewhere the light is still announced.
        if (_redLightCameraNear(a.routeMeters)) continue;
      }
      // Already spoken in this zone → try the next candidate instead of giving
      // up on this fix (that was the starvation bug above).
      if (_signDedupe.seen(signCalloutSig(a.sign, near: near))) continue;
      final tier = signAnnounceTier(k);
      if (tier < bestTier || (tier == bestTier && a.routeMeters < m)) {
        next = a.sign;
        m = a.routeMeters;
        bestTier = tier;
      }
    }
    if (next == null) return;
    final near = m <= 100;
    final phrase = signCalloutPhrase(next.kind, m, near: near);
    _logAnnouncement(phrase, kind: 'sign');
    // The built-up boundary and the "obey now" set are worth interrupting the
    // AI assistant / a camera line for; a turn or lane plate is not. They were
    // all priorityNormal before, so a boundary could be queued behind chatter.
    _voice.speak(
      phrase,
      priority: signAnnounceTier(next.kind) <= 1
          ? VoiceGuide.priorityHigh
          : VoiceGuide.priorityNormal,
    );
    if (mounted) setNavState(() {});
  }

  /// Is the upcoming camera alert the SAME junction as a traffic light
  /// [signMeters] ahead? Only a red-light camera counts: at those the camera
  /// alert and the light callout describe one hazard, and the camera one is the
  /// more informative of the two (see the guard in [_announceSigns]).
  bool _redLightCameraNear(double signMeters) {
    final cam = _nextCamera;
    if (cam == null) return false;
    final c = cam.camera;
    if (c.focus != 'red_light' && c.type != 'red_light') return false;
    return (cam.routeMeters - signMeters).abs() <= 150;
  }
}

/// The spoken callout for a road sign, or for a khu đông dân cư boundary.
///
/// Pure so the voice can be pinned by a test (`test/sign_callout_phrase_test.dart`):
/// a phrase that has to be right for the driver must not live inside a widget.
///
/// [near] is the ~100 m (final) callout; otherwise the far one. Zone-referenced
/// kinds carry NO distance — see [signAheadTail] and [zoneSignKinds].
    String signCalloutPhrase(
  RoadSignKind kind,
  double meters, {
  required bool near,
}) => switch (kind) {
      RoadSignKind.stop =>
        near
            ? 'Biển STOP sắp tới'
            : 'Biển STOP phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.giveWay =>
        near
            ? 'Biển nhường đường sắp tới'
            : 'Biển nhường đường phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noPassing =>
        near
            ? 'Cấm vượt sắp tới'
            : 'Cấm vượt phía trước${signAheadTail(kind, meters)}',
      RoadSignKind.noLeftTurn =>
        near
            ? 'Cấm rẽ trái sắp tới'
            : 'Cấm rẽ trái phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noRightTurn =>
        near
            ? 'Cấm rẽ phải sắp tới'
            : 'Cấm rẽ phải phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noUTurn =>
        near
            ? 'Cấm quay đầu sắp tới'
            : 'Cấm quay đầu phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noLeftUTurn =>
        near
            ? 'Cấm rẽ trái và quay đầu sắp tới'
            : 'Cấm rẽ trái và quay đầu phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noRightUTurn =>
        near
            ? 'Cấm rẽ phải và quay đầu sắp tới'
            : 'Cấm rẽ phải và quay đầu phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noPassingEnd =>
        near
            ? 'Hết cấm vượt sắp tới'
            : 'Hết cấm vượt phía trước${signAheadTail(kind, meters)}',
      RoadSignKind.onlyStraight =>
        near
            ? 'Chỉ đi thẳng sắp tới'
            : 'Chỉ được đi thẳng phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.onlyRight =>
        near
            ? 'Chỉ rẽ phải sắp tới'
            : 'Chỉ được rẽ phải phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.onlyLeft =>
        near
            ? 'Chỉ rẽ trái sắp tới'
            : 'Chỉ được rẽ trái phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.endProhibitions =>
        near
            ? 'Hết mọi lệnh cấm sắp tới'
            : 'Hết mọi lệnh cấm phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.slowDown =>
        near
            ? 'Giảm tốc độ sắp tới'
            : 'Giảm tốc độ phía trước${signAheadTail(kind, meters)}',
      RoadSignKind.tollBooth =>
        near
            ? 'Trạm thu phí sắp tới'
            : 'Trạm thu phí phía trước${signAheadTail(kind, meters)}',
      RoadSignKind.railwayCrossing =>
        near
            ? 'Đường ngang giao với đường sắt sắp tới'
            : 'Đường ngang giao với đường sắt phía trước'
                  '${signAheadTail(kind, meters)}',
      RoadSignKind.tunnel =>
        near
            ? 'Hầm đường bộ sắp tới'
            : 'Hầm đường bộ phía trước${signAheadTail(kind, meters)}',
      RoadSignKind.noAuto =>
        near
            ? 'Cấm ô tô sắp tới'
            : 'Cấm ô tô phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noMoto =>
        near
            ? 'Cấm xe máy sắp tới'
            : 'Cấm xe máy phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noParking =>
        near
            ? 'Cấm đỗ xe sắp tới'
            : 'Cấm đỗ xe phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noStraight =>
        near
            ? 'Cấm đi thẳng sắp tới'
            : 'Cấm đi thẳng phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.noTurnBoth =>
        near
            ? 'Cấm rẽ trái và rẽ phải sắp tới'
            : 'Cấm rẽ trái và rẽ phải phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.oneWay =>
        near
            ? 'Đường một chiều sắp tới'
            : 'Đường một chiều phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.reservedLane =>
        near
            ? 'Làn dành riêng sắp tới'
            : 'Làn dành riêng phía trước ${formatDistanceSpoken(meters)}',
      RoadSignKind.signal =>
        // Near-only (see above), so the `near` branch is the one used.
        near
            ? 'Đèn giao thông sắp tới'
            : 'Đèn giao thông phía trước ${formatDistanceSpoken(meters)}',
      // Khu đông dân cư boundaries, in the driver's own words. No distance is
      // spoken: the point may be a zone-dump vertex (see [zoneSignKinds]).
      RoadSignKind.populated =>
        near ? 'Bắt đầu khu dân cư' : 'Bắt đầu khu dân cư phía trước',
      RoadSignKind.populatedEnd =>
        near ? 'Hết khu dân cư' : 'Hết khu dân cư phía trước',
      _ =>
        near
            ? 'Cấm rẽ phải và quay đầu sắp tới'
            : 'Cấm rẽ phải và quay đầu phía trước ${formatDistanceSpoken(meters)}',
    };
