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
  // ⛔ `oneWay` is deliberately MAP-ONLY (user, 2026-10-11: "no need anounce,
  // just show the sign"). The pack now carries ~17.8k I.407a rows generated
  // from the segment layer's one-way data, one at each end of every one-way run
  // ≥85 m — announcing each one would fire on nearly every block of a district
  // like Quận 1, where ~1,700 segments are one-way. The SIGN is the information;
  // the callout is noise.
  RoadSignKind.reservedLane,
  RoadSignKind.tollBooth,
  RoadSignKind.railwayCrossing,
  RoadSignKind.tunnel,
  RoadSignKind.slowDown,
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
  RoadSignKind.tollBooth ||
  RoadSignKind.railwayCrossing ||
  RoadSignKind.tunnel ||
  RoadSignKind.slowDown ||
  RoadSignKind.signal => 1,
  _ => 2,
};

/// Dedupe key for a sign callout: kind + the sign's own position.
///
/// ⭐ ONE callout per plate — no far + near pair. The pair was designed as
/// "approach, then final reminder", but at 1 Hz with a corridor full of plates
/// it reads as spam: "biển KDC nói đúng 1 lần, cấm vượt nói đúng 1 lần chứ trái
/// phải nói hết" (user, 2026-10-25). The distance is in the sentence, so the
/// driver hears where it is on the first callout.
String signCalloutSig(RoadSign sign) =>
    '${sign.kind.key}/${sign.lat.toStringAsFixed(5)},'
    '${sign.lng.toStringAsFixed(5)}';

extension _NavSigns on _NavigationPageState {
  /// Seed the built-up state from the first R.420/R.421 boundary sign along
  /// the route, before the first GPS fix.
  ///
  /// The POI/segment-density probe in `urban_area.dart` is only a fallback: it
  /// cannot distinguish a highway passing a dense district from the district
  /// itself (QL1 near Dầu Giây was called urban on every sampled Waze segment,
  /// capping a real 90 to 60). A boundary sign IS the legal zone transition — but
  /// only the NEXT one describes the zone the driver is in now, so the seed is
  /// bounded by [kTownSeedAheadM]; see [townSeedFromBoundary]. Farther out the
  /// density seed stands (it describes where the car actually is).
  Future<void> _seedTownFromRouteSigns() async {
    final route = _route;
    if (route == null || route.geometry.length < 2) return;
    try {
      final ahead = await signsAheadOnRoute(
        route.geometry.first,
        route.geometry,
        maxAheadMeters: 30000,
        lateralMeters: 60.0,
      );
      if (!mounted || !identical(_route, route)) return;
      SignAhead? first;
      for (final a in ahead) {
        final k = a.sign.kind;
        if (k == RoadSignKind.populated || k == RoadSignKind.populatedEnd) {
          first = a;
          break;
        }
      }
      if (first == null) return; // no boundary data: density fallback stands
      final inTown = townSeedFromBoundary(
        isEndSign: first.sign.kind == RoadSignKind.populatedEnd,
        aheadM: first.routeMeters,
      );
      if (inTown == null) {
        debugPrint(
          'TOWN: not seeded from ${first.sign.kind.key} @ '
          '${first.routeMeters.round()} m — too far to describe the zone '
          'here; density decides',
        );
        return;
      }
      setNavState(() {
        _inTownBySign = true;
        _inTown = inTown;
        _inTownPos = null;
      });
      _updateRoadForTownChange(inTown, at: _current);
      debugPrint(
        'TOWN: seeded inTown=$inTown from '
        '${first.sign.kind.key} @ ${first.routeMeters.round()} m',
      );
    } catch (_) {
      // Best-effort: no sign seed leaves the density fallback untouched.
    }
  }

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
      // 60 m, not kRoadsideLateralMeters (40 m): sign coordinates come from
      // the source packs (often the road segment, not the carriageway edge),
      // so 60 m keeps a roadside post on a wide avenue while still excluding
      // the next block. The route MAP uses the same corridor; zone signs keep
      // their wider kZoneLateralMeters.
      lateralMeters: 60.0,
    );
    if (!mounted) return;
    // The display bar is fed FIRST — before the `if (!_voiceOn) return` gate
    // below — so "biển báo phía trước" works with the voice off.
    _setSignsAhead(ahead);
    // 1. Process signs reached within [kSignReachedM] (50 m):
    final reachedSigns = ahead
        .where((a) => a.routeMeters <= kSignReachedM)
        .toList();
    var reachedTownBoundary = false;
    var stateChanged = false;

    // ⭐ ONE boundary per fix — the NEAREST one. R.420 and R.421 are posted as a
    // PAIR a few metres apart (one per direction) at every real transition, and
    // a zone sign is accepted from 150 m off the route (it is stored at an area
    // vertex, not on the carriageway), so a single fix can "reach" both plates.
    // Applying both entered and immediately left the zone, and the state then
    // depended on which record happened to sort last: the driver was told
    // "Bắt đầu khu dân cư" and then given the rural table, or the reverse (user,
    // 2026-10-24: "sai cái vụ ra vào khu dân cư"). The nearest plate is the
    // transition the car is actually crossing.
    RoadSignKind? reachedZone;
    var nearestZoneM = double.infinity;
    for (final a in reachedSigns) {
      final k = a.sign.kind;
      if (k != RoadSignKind.populated && k != RoadSignKind.populatedEnd) {
        continue;
      }
      if (a.routeMeters < nearestZoneM) {
        nearestZoneM = a.routeMeters;
        reachedZone = k;
      }
    }

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
          stateChanged = true;
        }
        continue;
      }
      if (k != reachedZone) continue; // one boundary per fix — see above
      if (k == RoadSignKind.populated || k == RoadSignKind.populatedEnd) {
        // An expressway / ramp / toll plaza has no khu dân cư boundary, and the
        // packs put plates near the barriers: skip them there (see
        // [_noteLayerStep] for the measured toll-plaza case). Both the road on
        // screen and the segment under the car count — measured 2026-10-30, a
        // plate beside CT HCM-Long Thành-Dầu Giây still announced "Bắt đầu khu
        // dân cư" because only the segment was consulted.
        if (isLimitedAccessRoad(_roadInfo?.name) ||
            isMixedLane(_roadInfo?.name) ||
            lastWazeIsLimitedAccess()) {
          continue;
        }
        debugPrint(
          'SIGNS: zone plate ${k.key} on "${_roadInfo?.name}" '
          '(layer limited=${lastWazeIsLimitedAccess()})',
        );
        final enteringPlate = k == RoadSignKind.populated;
        // The posted layer owns the zone while it answers: a plate that says
        // the opposite is the other carriageway's or a misplaced point.
        if (_inTownByLayer && enteringPlate != _inTown) continue;
        // …and a plate of the opposite kind right after a transition needs the
        // layer to have moved the same way.
        if (_zoneFlipBlocked(k, snapped)) continue;
        reachedTownBoundary = true;
        if (_inTown != enteringPlate) {
          _inTown = enteringPlate;
          _inTownBySign = true;
          _updateRoadForTownChange(enteringPlate, at: snapped);
          stateChanged = true;
          // ⭐ The sentence belongs to the CHANGE, not to a separate path — see
          // [_announceZone].
          _announceZone(enteringPlate, snapped);
        } else if (!_inTownBySign) {
          // Plate agrees with the layer: it takes over the authority so a later
          // layer step cannot drag the zone back on its own.
          _inTownBySign = true;
        }
      }
    }

    // Explicit speed limit signs reached (P.127):
    final reachedSpeed = reachedSigns
        .where((a) => a.sign.kind == RoadSignKind.speed && a.sign.value != null)
        .firstOrNull;

    if (reachedSpeed != null) {
      if (reachedSpeed.sign.value != _signSpeedLimit) {
        _signSpeedLimit = reachedSpeed.sign.value;
        _signSpeedLimitRoad = _roadInfo?.name;
        _signAheadM = 0;
        stateChanged = true;
      }
    } else if (reachedTownBoundary) {
      // Crossing a built-up boundary without an explicit speed sign posted at
      // the boundary terminates any prior open-road / urban sign limit, reverting
      // to the statutory table for the new zone.
      if (_signSpeedLimit != null) {
        _signSpeedLimit = null;
        _signSpeedLimitRoad = null;
        _signAheadM = 0;
        stateChanged = true;
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
        stateChanged = true;
      } else if (_signSpeedLimitRoad == null || _signSpeedLimitRoad!.isEmpty) {
        // Bind road name as soon as it becomes known.
        if (curRoad != null && curRoad.isNotEmpty) {
          _signSpeedLimitRoad = curRoad;
        }
      }
    }

    if (stateChanged && mounted) setNavState(() {});

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
      // Built-up boundaries are ZONE state, not one-off plates: the source
      // packs carry many R.420/R.421 points along the same boundary (and Waze
      // repeats them every few hundred metres). Once we are already inside /
      // outside by sign, another same-direction boundary is noise — announce
      // only the first transition, and only the nearest boundary of each kind
      // in this scan.
      // Zone plates are NOT spoken from here: a built-up transition is a change
      // of STATE and is announced where the state changes (see [_announceZone]),
      // so one boundary cannot be reported twice and an "ahead" sentence cannot
      // contradict what the posted layer says under the bike.
      if (k == RoadSignKind.populated || k == RoadSignKind.populatedEnd) {
        continue;
      }
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
      if (_signDedupe.seen(signCalloutSig(a.sign))) continue;
      final tier = signAnnounceTier(k);
      if (tier < bestTier || (tier == bestTier && a.routeMeters < m)) {
        next = a.sign;
        m = a.routeMeters;
        bestTier = tier;
      }
    }
    if (next == null) return;
    if (_prohibitionBlocked(next.kind, snapped)) return;
    final near = m <= 100;
    final phrase = signCalloutPhrase(next.kind, m, near: near);
    if (next.kind == RoadSignKind.populated ||
        next.kind == RoadSignKind.populatedEnd) {
      _lastZoneKind = next.kind;
      _lastZoneAt = snapped;
      _lastZoneLayerKmh = _lastLayerKmh;
    }
    // WHICH SIDE the plate that produced this sentence stands on, measured
    // against the same route polyline the scan used. The scan already refuses
    // left-hand plates (see `pointsAheadOnRoute.rightSideFor`); this line is
    // what makes that auditable from a drive log instead of assumed
    // (`tool/sign_side_audit.py` measures the data, not the app's decision).
    debugPrint(
      'SIGNS: callout ${next.kind.key} dx=${(signedLateralOffsetMeters(geometry, next.pos) ?? 0).toStringAsFixed(1)} m ahead=${m.round()} m',
    );
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

  /// True when this no-overtaking plate must stay silent.
  ///
  /// CẤM VƯỢT (P.125) is a long ban and the packs are noisy about it: `noPassing`
  /// rows sit 1 m from their `noPassingEnd` at the same post, and the plate is
  /// repeated every couple of kilometres along one ban. Measured 2026-10-25, km
  /// 40,6 / 41,5 / 42,2 were three sentences in 2 s; measured 2026-10-29, the
  /// remaining noise was two identical "hết cấm vượt" 540 m apart.
  ///
  /// So the ban is read as a STATE, not as a stream of plates — the policy itself
  /// lives in [prohibitionSuppressed] so it can be tested.
  bool _prohibitionBlocked(RoadSignKind kind, LatLng at) {
    final startsBan = kind == RoadSignKind.noPassing;
    if (!startsBan && kind != RoadSignKind.noPassingEnd) return false;
    final lastKind = _lastProhibitionKind;
    final lastAt = _lastProhibitionAt;
    final zoneAt = _lastZoneAt;
    final suppressed = prohibitionSuppressed(
      startsBan: startsBan,
      bannedNow: _noPassing,
      oppositeNear:
          lastKind != null &&
          lastAt != null &&
          lastKind != kind &&
          distanceMeters(lastAt, at) < kProhibitionFlipM,
      zoneNear:
          zoneAt != null && distanceMeters(zoneAt, at) < kZoneProhibitionGapM,
    );
    if (suppressed) return true;
    _noPassing = startsBan;
    _lastProhibitionKind = kind;
    _lastProhibitionAt = at;
    return false;
  }

  /// Speak a khu dân cư transition ONCE per state change, whatever moved it.
  ///
  /// Both sources move `_inTown` — a reached plate and the posted-layer step.
  /// The sentence used to hang off a third path (the call-out loop), so a plate
  /// could move the state silently and the next layer step then announced a
  /// transition the driver never heard begin: measured 2026-10-28 on the 176 km
  /// drive, "Hết khu dân cư" at km 110,7 and again at 120,6 with nothing said
  /// in between, because a plate had set "inside" at ~114,9 without a word.
  void _announceZone(bool entering, LatLng at) {
    if (_announcedInTown == entering) return;
    // ⭐ TWO SENTENCES MUST NOT SHARE ONE CORNER. The state follows the road —
    // the statutory limit and the chip change immediately — but a change that
    // lands within [kZoneMinGapM] of the last sentence is heard as one noise
    // burst, and it was measured as a real defect: QL1/QL20 at 110 km/h logged
    // "Hết" and "Bắt đầu" 1 ms apart (two lookups disagreeing on the same fix)
    // and 180 m apart on the CT01 approach, while lane changes on Mai Chí Thọ
    // flipped the zone 8 times in 8 minutes.
    final lastAt = _lastZoneAt;
    if (lastAt != null && distanceMeters(lastAt, at) < kZoneMinGapM) {
      _announcedInTown = entering;
      debugPrint(
        'TOWN: ${entering ? 'vào' : 'ra'} — giữ im lặng '
        '(${distanceMeters(lastAt, at).round()} m < ${kZoneMinGapM.round()} m)',
      );
      return;
    }
    _announcedInTown = entering;
    _lastZoneKind = entering
        ? RoadSignKind.populated
        : RoadSignKind.populatedEnd;
    _lastZoneAt = at;
    _lastZoneLayerKmh = _lastLayerKmh;
    final phrase = entering ? 'Bắt đầu khu dân cư' : 'Hết khu dân cư';
    debugPrint(
      'TOWN: ${entering ? 'vào' : 'ra'} khu dân cư (lớp Waze '
      '$_lastLayerKmh km/h)',
    );
    _logAnnouncement(phrase, kind: 'sign');
    _voice.speak(phrase, priority: VoiceGuide.priorityHigh);
  }

  /// Would announcing [kind] flip the zone we just announced, without the
  /// posted LAYER agreeing?
  ///
  /// The layer's step is the positional evidence: 80/90 → 60 or less is a town
  /// entry, the reverse is the exit (`_noteLayerStep` reads the same step). A
  /// plate of the opposite kind inside [kZoneFlipGuardM] that the layer does not
  /// back up is the other direction's plate (or a duplicate of the same post).
  bool _zoneFlipBlocked(RoadSignKind kind, LatLng at) {
    final last = _lastZoneKind;
    final at0 = _lastZoneAt;
    if (last == null || at0 == null || last == kind) return false;
    if (distanceMeters(at0, at) > kZoneFlipGuardM) return false;
    final delta = _lastLayerKmh - _lastZoneLayerKmh;
    final entering = kind == RoadSignKind.populated;
    return entering ? delta < 20 : delta > -20;
  }

  /// Record the signs ahead for the "sắp tới" alert bar, nearest first.
  ///
  /// Rebuilds only when the nearest sign changes or its distance moves a whole
  /// metre, so a 1 Hz scan does not repaint the nav screen every second.
  void _setSignsAhead(List<SignAhead> ahead) {
    final sorted = [...ahead]
      ..sort((a, b) => a.routeMeters.compareTo(b.routeMeters));
    // ONE hazard per junction: a no-overtaking plate standing at a built-up
    // boundary (45–69 m measured, 2026-10-29) is the same event, and the bar
    // showed both — the boundary wins, exactly as it does in the voice.
    final boundaries = sorted
        .where(
          (a) =>
              a.sign.kind == RoadSignKind.populated ||
              a.sign.kind == RoadSignKind.populatedEnd,
        )
        .map((a) => a.routeMeters)
        .toList();
    if (boundaries.isNotEmpty) {
      sorted.removeWhere(
        (a) =>
            (a.sign.kind == RoadSignKind.noPassing ||
                a.sign.kind == RoadSignKind.noPassingEnd) &&
            boundaries.any(
              (z) => (z - a.routeMeters).abs() < kZoneProhibitionGapM,
            ),
      );
    }
    final unchanged =
        sorted.length == _aheadSigns.length &&
        List.generate(sorted.length, (i) => i).every(
          (i) =>
              identical(sorted[i].sign, _aheadSigns[i].sign) &&
              sorted[i].routeMeters.round() ==
                  _aheadSigns[i].routeMeters.round(),
        );
    if (unchanged) return;
    _aheadSigns = sorted;
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
    return redLightCameraCoversJunction(
      signMeters: signMeters,
      cameraMeters: cam.routeMeters,
      isRedLightCamera: c.focus == 'red_light' || c.type == 'red_light',
    );
  }
}

/// Short name for a sign, for the alert bar's long-press tooltip.
///
/// [RoadSignKind.label] is written for the catalogue and carries the QCVN code
/// ("P.123 Cấm rẽ trái"), which is noise on a tooltip for an icon whose whole
/// point is that the picture identifies it; this strips the code. The two
/// symbols every rider knows by name are shortened further.
///
/// Pure, so the bar's wording can be pinned by a test.
String signShortLabel(RoadSignKind kind) {
  if (kind == RoadSignKind.stop) return 'STOP';
  if (kind == RoadSignKind.giveWay) return 'Nhường đường';
  return kind.label.replaceFirst(RegExp(r'^[A-Z]+\.\d+[a-z]?\s+'), '').trim();
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
