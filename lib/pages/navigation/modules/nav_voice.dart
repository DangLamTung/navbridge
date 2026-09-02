part of '../navigation_page.dart';

extension _NavVoice on _NavigationPageState {
  /// Open the AI assistant chat panel. [question] is auto-sent on open (e.g.
  /// from the voice command "hỏi AI …"); null opens an empty chat.
  Future<void> _openAiAssistant({String? question}) async {
    if (!mounted) return;
    // Fetch weather now (if not already) so the AI can answer weather
    // questions even before a route starts. Open-Meteo is fast (~1 s).
    await _ensureWeather();
    if (!mounted) return;
    // Compute the route-aware trip context (cameras/đèo/gas ahead from the
    // offline DB) so the AI can answer "còn bao nhiêu camera", "bao giờ hết
    // đèo", "trạm xăng còn xa không" grounded in real data.
    final aiCtx = await _aiContextAsync();
    if (!mounted) return;
    // Let the panel use OUR mic (shares permissions/state with the nav
    // screen) instead of spinning up its own recognizer.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      // The modal sheet's builder context reliably reports the on-screen
      // keyboard via viewInsets — this Padding lifts the whole panel above the
      // keyboard so the question field is never blocked while typing.
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: AiChatPanel(
          context: aiCtx,
          initialQuestion: question?.trim(),
          // Opened by a voice command → speak the answer aloud while it streams
          // so the driver never has to look at the screen.
          speakAloud: question != null && question.trim().isNotEmpty,
          onSpeak: (sentence) {
            if (sentence.isEmpty) {
              _voice.stop(); // flush any queued spoken answer
            } else {
              _voice.speakQueued(sentence);
            }
          },
          // "Đi đến" chip on an AI-grounded place → plan the route.
          onNavigate: (name, lat, lng) {
            unawaited(_planToPoint(name, lat, lng));
          },
          onMicPressed: () async {
            final mic = await Permission.microphone.request();
            if (!mic.isGranted) return '';
            if (!mounted) return '';
            return _recognizeOnePhrase();
          },
        ),
      ),
    );
  }

  /// One-shot voice recognition returning the recognized phrase (or '').
  /// The window is capped (~15 s) and ALWAYS resolves — a failed session on
  /// this device (no_match) would otherwise leave the chat mic waiting forever.
  Future<String> _recognizeOnePhrase() async {
    if (!_commands.available) return '';
    // If the nav voice (or the always-on wake word) is already listening, a
    // SECOND recognizer start returns no result (speech_to_text throws/silent
    // on double-start) — stop it first so the AI mic actually works while
    // navigating. The always-on loop re-arms itself on the next toggle.
    if (_listening || _alwaysOnVoice) {
      _listening = false;
      _alwaysOnVoice = false;
      if (mounted) setNavState(() {});
      await _commands.stop();
    }
    final completer = Completer<String>();
    _listening = true;
    if (mounted) setNavState(() {});
    await _commands.listen(
      completer.complete,
      onPartial: (_) {},
      budget: const Duration(seconds: 15),
    );
    _listening = false;
    if (mounted) setNavState(() {});
    if (!completer.isCompleted) completer.complete('');
    return completer.future;
  }

  /// Build the live drive context the AI assistant grounds its answers in.
  AiContext _aiContext() {
    final cur = _current;
    final nav = _progress;
    final cam = _nextCamera;
    final w = _weather;
    final road = _roadInfo;
    return AiContext(
      position: cur == null
          ? null
          : '${cur.latitude.toStringAsFixed(4)}, '
                '${cur.longitude.toStringAsFixed(4)}',
      road: road == null
          ? null
          : '${road.label.isNotEmpty
                    ? road.label
                    : road.name.isNotEmpty
                    ? road.name
                    : road.highway}'
                '${road.speedLimit > 0 ? ' (${road.speedLimit} km/h)' : ''}',
      speedKmh: _lastSpeedMps > 0
          ? '${(_lastSpeedMps * 3.6).round()} km/h'
          : null,
      destination: _destinationName,
      eta: nav == null
          ? null
          : '${nav.etaHour.toString().padLeft(2, '0')}:'
                '${nav.etaMinute.toString().padLeft(2, '0')}',
      nextManeuver: nav == null
          ? null
          : '${nav.text.isEmpty ? 'lượt tiếp' : nav.text} '
                'còn ${formatDistanceSpoken(nav.meter)}',
      cameraAhead: cam == null
          ? null
          : 'Camera ${cam.camera.name} phía trước '
                '${formatDistanceSpoken(cam.routeMeters)}',
      weather: _weatherText(w),
      radar: _rainPredictionText(w),
      tripNotes: _stops.isEmpty
          ? null
          : 'Hành trình ${_stops.length} điểm dừng',
      center: _current,
    );
  }

  /// Async [_aiContext] that ALSO computes route facts from the offline DB:
  /// cameras ahead (~10 km), đèo (mountain-pass) segments ahead on the route,
  /// and the nearest fuel station ahead on the route. This lets the AI answer
  /// "còn bao nhiêu camera", "bao giờ hết đèo", "trạm xăng còn xa không"
  /// grounded in real data (not a guess).
  Future<AiContext> _aiContextAsync() async {
    final cur = _current;
    final route = _route?.geometry ?? const <LatLng>[];
    int? camerasAhead;
    double? gasNextKm;
    if (cur != null && route.length >= 2) {
      try {
        final ahead = await camerasAheadOnRoute(
          cur,
          route,
          maxAheadMeters: 10000,
        );
        camerasAhead = ahead.length;
      } catch (_) {}
      try {
        final fuel = await poisInCategory('fuel', near: cur, limit: 24);
        if (fuel.isNotEmpty) {
          final startIdx =
              (_engine?.snappedSegmentIndex ?? 0).clamp(
                    0,
                    max(0, route.length - 1),
                  )
                  as int;
          double? ng;
          for (final p in fuel) {
            final proj = projectOnRoute(
              route,
              LatLng(p.lat, p.lng),
              startIndex: startIdx,
            );
            if (proj.aheadMeters >= -100 &&
                (ng == null || proj.aheadMeters < ng)) {
              ng = proj.aheadMeters;
            }
          }
          gasNextKm = ng == null ? null : ng / 1000.0;
        }
      } catch (_) {}
    }
    // Count đèo (mountain-pass) segments ahead: a route step whose road name
    // contains "đèo" (e.g. "Đèo Mimosa", "QL20 Đèo Bảo Lộc").
    var passes = 0;
    for (final s in _route?.steps ?? const <OsrmStep>[]) {
      if (s.name.toLowerCase().contains('đèo')) passes++;
    }
    final nav = _progress;
    final base = _aiContext();
    final hard = await _hardSectionsText();
    return AiContext(
      position: base.position,
      road: base.road,
      speedKmh: base.speedKmh,
      destination: base.destination,
      eta: base.eta,
      nextManeuver: base.nextManeuver,
      cameraAhead: base.cameraAhead,
      weather: base.weather,
      radar: base.radar,
      tripNotes: base.tripNotes,
      routeRemainingKm: nav == null
          ? null
          : 'còn ${(nav.remainingMeters / 1000).round()} km đến điểm đến',
      camerasAhead: camerasAhead,
      passesAhead: passes > 0 ? passes : null,
      gasNextKm: gasNextKm,
      hardSections: hard,
      center: base.center,
    );
  }

  /// Describe the difficult/hazardous section AHEAD: winding curves (computed
  /// from the route geometry — the non-named "đèo" the driver feels), plus
  /// tunnel / railway / slow-down / cấm vượt signs, plus any đèo-named road
  /// segment. Null when the road ahead is easy.
  Future<String?> _hardSectionsText() async {
    final cur = _current;
    final route = _route?.geometry ?? const <LatLng>[];
    if (cur == null || route.length < 2) return null;
    final parts = <String>[];
    // 1) Đèo-named road segments ahead (heuristic — most passes are named in
    // the road, e.g. "Đèo Mimosa", but it is NOT exact).
    var passes = 0;
    for (final s in _route?.steps ?? const <OsrmStep>[]) {
      if (s.name.toLowerCase().contains('đèo')) passes++;
    }
    if (passes > 0) parts.add('$passes đoạn đèo');
    // 2) Hazard signs ahead (tunnel / railway / slow-down / cấm vượt).
    try {
      final ahead = await signsAheadOnRoute(cur, route, maxAheadMeters: 15000);
      var tunnel = 0, rail = 0, slow = 0, noPass = 0;
      for (final a in ahead) {
        switch (a.sign.kind) {
          case RoadSignKind.tunnel:
            tunnel++;
          case RoadSignKind.railwayCrossing:
            rail++;
          case RoadSignKind.slowDown:
            slow++;
          case RoadSignKind.noPassing:
            noPass++;
          default:
            break;
        }
      }
      if (tunnel > 0) parts.add('$tunnel hầm');
      if (rail > 0) parts.add('$rail đường ngang giao với đường sắt');
      if (slow > 0) parts.add('$slow đoạn giảm tốc độ');
      if (noPass > 0) parts.add('$noPass đoạn cấm vượt');
    } catch (_) {}
    // 3) Winding (curvy) stretches — the non-named "đèo" the driver feels.
    final windingKm = _windingKm(route);
    if (windingKm != null && windingKm >= 2) {
      parts.add('$windingKm km đường uốn gắt');
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Rough "winding km" on the route: count (~2 km) windows where the cumulative
  /// heading change is >300° (a local geometry heuristic — no sign data, so it
  /// catches difficult sections not named "đèo").
  int? _windingKm(List<LatLng> route) {
    if (route.length < 3) return null;
    double heading = _bearingDeg(route[0], route[1]);
    double accum = 0;
    double km = 0;
    double since = 0;
    const windowM = 2000.0;
    const thresh = 300.0;
    for (var i = 1; i + 1 < route.length; i++) {
      final h = _bearingDeg(route[i], route[i + 1]);
      var d = (h - heading).abs() % 360;
      if (d > 180) d = 360 - d;
      accum += d;
      heading = h;
      since += fastDistanceMeters(route[i], route[i + 1]);
      if (since >= windowM) {
        if (accum >= thresh) km += windowM / 1000.0;
        accum = 0;
        since = 0;
      }
    }
    return km >= 1 ? km.round() : null;
  }

  /// Bearing (deg, 0=N) from [a] to [b] (local equirectangular — fine at city
  /// scale).
  double _bearingDeg(LatLng a, LatLng b) {
    const pi = 3.141592653589793;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180.0 / pi + 360) % 360;
  }

  /// "30°C, mưa nhẹ" for the AI context (null when no weather yet).
  String? _weatherText(WeatherInfo? w) {
    if (w == null || w.tempC == null) return null;
    final cond = weatherTextForCode(w.weatherCode);
    return cond.isEmpty ? '${w.tempC}°C' : '${w.tempC}°C, $cond';
  }

  /// "mưa 80% trong giờ tới; từng giờ: 13h 80%, 14h 40%, 15h 10%" for the AI
  /// context — the radar-based rain prediction (Open-Meteo hourly probability)
  /// plus the full hourly timeline so the assistant can answer "mưa tạnh lúc
  /// mấy giờ". Null when the feed has no probability.
  String? _rainPredictionText(WeatherInfo? w) {
    final p = w?.rainProbSoon;
    final tl = rainTimelineText(w?.rainProb);
    final base = p == null
        ? null
        : p >= 50
        ? 'mưa khả năng cao $p% trong giờ tới'
        : p >= 30
        ? 'khả năng mưa $p% trong giờ tới'
        : 'khả năng mưa thấp $p% trong giờ tới';
    if (base == null) return tl.isEmpty ? null : 'Dự báo mưa từng giờ: $tl';
    return tl.isEmpty ? base : '$base; từng giờ: $tl';
  }

  /// Speak the upcoming maneuver AHEAD of the turn at speed-aware distances
  /// so the Bluetooth-speaker announcement always lands before the maneuver
  /// (never after it): first heads-up ~`max(150, speed×20)` m out, a closer
  /// heads-up ~`max(80, speed×8)` m, then a final "rẽ trái" at ~40 m. At
  /// speed, the callouts move earlier; the fixed fallbacks keep them sane
  /// when stationary.
  void _maybeSpeakManeuver(NavProgress nav) {
    if (!_voiceOn || !_voice.ready) return;
    if (nav.iconCode == iconArrive) {
      if (_arrivedSpoken) return;
      _arrivedSpoken = true;
      // "Điểm đến bên trái/phải" — help the driver spot the target when it's
      // near: project the destination onto the route and say which side of
      // the road it's on (right-hand traffic: same side = no U-turn).
      final route = _route?.geometry ?? const <LatLng>[];
      final startIdx =
          (_engine?.snappedSegmentIndex ?? 0).clamp(0, max(0, route.length - 1))
              as int;
      String side = '';
      if (route.length >= 2) {
        final dest = nav.maneuver ?? _destination;
        if (dest != null) {
          final proj = projectOnRoute(route, dest, startIndex: startIdx);
          // Only when the destination is genuinely close ahead.
          if (proj.aheadMeters > -200 && proj.aheadMeters < 400) {
            side = proj.lateralMeters > 0 ? ' bên trái.' : ' bên phải.';
          }
        }
      }
      _voice.speak(
        side.isEmpty ? 'Bạn đã đến nơi.' : 'Điểm đến$side',
        priority: VoiceGuide.priorityCritical,
      );
      return;
    }
    final m = nav.meter;
    final speed = nav.speedMps.isFinite ? nav.speedMps : 0.0;
    // Head-up callouts are timed in SECONDS before the maneuver so they ALWAYS
    // sound ahead of the turn (never after — even with TTS + Bluetooth
    // latency): far ≈ 20 s out, near ≈ 12 s out, final ≈ 8 s out. On a long
    // straight stretch nothing repeats until the next maneuver gets close.
    // The FIRST callout is ~300-400 m out (was 200 m — too late in town); the
    // driver wants the turn told before the intersection, not on top of it.
    final far = max(350.0, speed * 20.0); // first heads-up (20 s out)
    final near = max(120.0, speed * 12.0); // closer heads-up (12 s out)
    final finalM = max(80.0, speed * 8.0); // final "rẽ trái" (8 s out)
    // A maneuver is new when the turn instruction changes. The signature
    // includes the street you turn INTO (`nextText`) + the maneuver's
    // coordinates so two CONSECUTIVE turns that share the same icon + road
    // name (complex multi-turn areas) still count as different and each is
    // announced. (The old "distance jumped up by 50 m" test misfired on
    // GPS/SIM jitter, re-announcing the same turn.)
    final mv = nav.maneuver;
    final sig =
        '${nav.iconCode}|${nav.nextText}|'
        '${mv?.latitude.toStringAsFixed(5) ?? '0'},'
        '${mv?.longitude.toStringAsFixed(5) ?? '0'}';
    final isNew = sig != _lastManeuverSig;
    if (isNew) {
      _lastManeuverSig = sig;
      _spokenFar = false;
      _spokenNear = false;
      _spokenFinal = false;
      // A turn is coming — reload the sign/camera layer for the road we are
      // heading into so the driver sees what's on the next stretch right away
      // (instead of waiting for the 5 s refresh). The route-ahead projection
      // already covers the new segment after the turn.
      unawaited(_refreshRouteCameras());
    }
    if (isNew && m > far) {
      // Fresh turn → announce it immediately with its distance.
      _spokenFar = true;
      _voice.speak(_announce(nav, m), priority: VoiceGuide.priorityCritical);
    } else if (!_spokenFar && m <= far && m > near) {
      _spokenFar = true;
      _voice.speak(_announce(nav, m), priority: VoiceGuide.priorityCritical);
    } else if (!_spokenNear && m <= near && m > finalM) {
      _spokenNear = true;
      _voice.speak(_announce(nav, m), priority: VoiceGuide.priorityCritical);
    } else if (!_spokenFinal && m <= finalM) {
      _spokenFinal = true;
      _voice.speak(
        _announce(nav, m, now: true),
        priority: VoiceGuide.priorityCritical,
      );
    }
  }

  String _announce(NavProgress nav, int m, {bool now = false}) {
    final verb = maneuverVerb(nav.iconCode);
    // "đi a b c, sau đó next move" — say the road you're ON first, then the
    // maneuver. `text` is the current road (what the car is travelling);
    // `nextText` is the road you turn INTO for the upcoming maneuver.
    final cur = nav.text.isNotEmpty ? nav.text : '';
    final target = nav.nextText.isNotEmpty ? nav.nextText : '';
    final onRoad = cur.isNotEmpty ? ' trên $cur' : '';
    // Emphasize the road you turn INTO — that's the part the driver needs.
    final into = target.isNotEmpty ? ' vào $target' : '';
    // Next-NEXT maneuver (priority 2): when there is one coming up, say it so
    // the driver can plan two moves ahead — "rẽ trái vào X, sau đó rẽ phải
    // vào Y". The board's nav2 packet already shows it; the voice now says it.
    String nextNext = '';
    if (nav.nextIconCode != 0 && nav.nextNextText.isNotEmpty) {
      final v2 = maneuverVerb(nav.nextIconCode);
      // Only when the 2nd move is reasonably near (it's the turn after the
      // upcoming one; beyond ~2 km it's noise on a long straight).
      if (nav.nextMeter <= 0 || nav.nextMeter <= 2000) {
        nextNext = ', sau đó $v2 vào ${nav.nextNextText}';
      }
    }
    // Announce the effective speed limit of the current road (item 2) — the
    // value shown in the road-info chip (sign-aware: the last speed-limit sign
    // passed wins over the road's default). Omitted when unknown (0).
    final limit = _effectiveSpeedLimit;
    final limitTxt = limit > 0 ? ' Tốc độ tối đa $limit km/h.' : '';
    if (now) {
      return '$verb$into$nextNext.$limitTxt';
    }
    return 'Đi$onRoad, sau ${formatDistanceSpoken(m)}, '
        '$verb$into$nextNext.$limitTxt';
  }

  /// Warn by voice when the driver EXCEEDS the road's speed limit. Announces
  /// once when the speeding episode starts, then at most every 60 s while
  /// still speeding (never a per-fix beep); resets when back within the limit
  /// (hysteresis). The ~5 km/h threshold ignores normal speedometer error.
  ///
  /// Voice stays SHORT and whole-number only: a plain "Vượt quá tốc độ" — the
  /// exact overage is spoken ONLY in the mild 5–10 km/h band (rounded to a
  /// whole km/h, never decimals); anything worse is just a firm simple
  /// "Giảm tốc độ!".
  void _maybeSpeakOverspeed(double speedMps) {
    if (!_voiceOn || !_voice.ready) return;
    if (!_navigating && !_simulating) return;
    // Sign-aware limit: the last speed-limit sign (incl. Waze per-segment)
    // passed wins over the road's default.
    final limit = _effectiveSpeedLimit;
    if (limit <= 0 || !speedMps.isFinite) return;
    final kmh = speedMps * 3.6;
    final over = kmh - limit;
    if (over >= 5) {
      final now = DateTime.now();
      final last = _lastOverspeedAt;
      if (!_speedingSpoken ||
          (last != null &&
              now.difference(last) >= const Duration(seconds: 60))) {
        _speedingSpoken = true;
        _lastOverspeedAt = now;
        // Whole-number speech only — never decimals. Mild overage (5–10 km/h)
        // states the exact (rounded) amount; more is just a firm simple alert.
        final msg = over < 10
            ? 'Vượt quá tốc độ ${over.round()} km/h.'
            : 'Giảm tốc độ! Vượt quá tốc độ.';
        _voice.speak(msg, priority: VoiceGuide.priorityHigh);
      }
    } else {
      _speedingSpoken = false;
    }
  }

  /// Speak when the effective speed limit CHANGES — crossing onto a road with
  /// a different posted limit (e.g. "Giới hạn 60 km/h") or entering/leaving a
  /// populated zone. Waits for the new limit to be stable ~2 s (road info can
  /// flicker) and never repeats within ~4 s, so a bumpy boundary can't spam.
  void _maybeSpeakLimitChange() {
    if (!_voiceOn || !_voice.ready) return;
    if (!_navigating && !_simulating) return;
    final limit = _effectiveSpeedLimit;
    if (limit <= 0) return;
    final now = DateTime.now();
    if (limit == _lastSpokenLimit) {
      _pendingLimit = null;
      _pendingSince = null;
      return;
    }
    if (limit != _pendingLimit) {
      // New candidate limit — arm the stability window.
      _pendingLimit = limit;
      _pendingSince = now;
      return;
    }
    if (_pendingSince == null ||
        now.difference(_pendingSince!) < const Duration(seconds: 2)) {
      return; // not yet stable
    }
    if (_lastLimitSpoke != null &&
        now.difference(_lastLimitSpoke!) < const Duration(seconds: 4)) {
      return; // cooldown from the last announcement
    }
    _lastLimitSpoke = now;
    _lastSpokenLimit = limit;
    _pendingLimit = null;
    _pendingSince = null;
    _voice.speak('Giới hạn $limit km/h', priority: VoiceGuide.priorityHigh);
  }

  /// Warn by voice when GPS quality is poor (reported accuracy ≥ 30 m) so the
  /// driver knows the fix may wander off the road. Announces once per degraded
  /// episode, then at most every 60 s while still bad; resets when the fix
  /// recovers under ~15 m (hysteresis). Only during navigation.
  void _maybeSpeakGpsWeak(double accuracyM) {
    if (!_voiceOn || !_voice.ready) return;
    if (!_navigating && !_simulating) return;
    if (!accuracyM.isFinite || accuracyM <= 0) return;
    if (accuracyM >= 30) {
      final now = DateTime.now();
      final last = _lastGpsWeakAt;
      if (!_gpsWeakSpoken ||
          (last != null &&
              now.difference(last) >= const Duration(seconds: 60))) {
        _gpsWeakSpoken = true;
        _lastGpsWeakAt = now;
        _voice.speak('Tín hiệu GPS yếu, vị trí có thể không chính xác.');
      }
    } else if (accuracyM < 15) {
      _gpsWeakSpoken = false;
    }
  }

  Future<void> _toggleListening() async {
    // Tap toggles ONE-SHOT listening. If always-on is active, a tap turns
    // everything off (mic red → back to normal).
    if (_listening || _alwaysOnVoice) {
      final wasAlwaysOn = _alwaysOnVoice;
      _listening = false;
      _alwaysOnVoice = false;
      if (mounted) setNavState(() {});
      await _commands.stop();
      // Stop the background voice service (unless nav keeps it alive).
      if (wasAlwaysOn && !_navigating) {
        await NavForegroundService.instance.stopVoiceService();
      }
      return;
    }
    if (!_commands.available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thiết bị này không hỗ trợ nhận diện giọng nói.'),
          ),
        );
      }
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cần quyền micro để điều khiển bằng giọng nói.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    // Set the listening state and banner TOGETHER so the first frame already
    // reads "Đang nghe…" — never the premature past-tense "Đã nhận lệnh".
    _voiceBannerTimer?.cancel();
    setNavState(() {
      _voiceText = '';
      _listening = true;
      _voiceBannerVisible = true;
    });
    // Keep the banner up while listening; auto-hide only after it ends.
    _voiceBannerTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _listening) return;
      setNavState(() {
        _voiceBannerVisible = false;
        _voiceText = '';
      });
    });
    // Hard cap on a single tap-to-talk window (~10 s): long enough for a
    // full command, short enough to never leave the mic "hanging" if the
    // driver stops talking and the recognizer doesn't finalize on its own.
    await _commands.listen(
      _onVoiceResult,
      onPartial: _onVoicePartial,
      budget: const Duration(seconds: 10),
    );
    // Window closed with no result → free the mic and tell the driver.
    if (!mounted) return;
    if (_listening) {
      setNavState(() {
        _listening = false;
        _voiceText = '';
      });
      _showVoiceBanner(); // shows "Không nghe rõ, thử lại"
    }
  }

  /// Live partial transcript while speaking → keep the "listening…" banner
  /// showing what the recognizer hears so far.
  void _onVoicePartial(String text) {
    if (!mounted) return;
    setNavState(() {
      _voiceText = text;
      _voiceBannerVisible = true;
    });
  }

  /// Show the mic banner (listening or recognized-text confirmation). Auto
  /// hides after a few seconds when no speech is active.
  void _showVoiceBanner() {
    _voiceBannerTimer?.cancel();
    if (!mounted) return;
    setNavState(() => _voiceBannerVisible = true);
    _voiceBannerTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setNavState(() {
        _voiceBannerVisible = false;
        _voiceText = '';
      });
    });
  }

  /// LONG-PRESS on the mic: toggle ALWAYS-ON wake-word listening. When on, the
  /// mic stays red and the recognizer keeps running, only acting when it hears
  /// "NavBridge, …" — fully hands-free. Long-press again (or say
  /// "tắt nghe luôn") to turn it off.
  Future<void> _toggleAlwaysOnVoice() async {
    if (_alwaysOnVoice) {
      _alwaysOnVoice = false;
      _listening = false;
      await _commands.stop();
      if (mounted) setNavState(() {});
      _voice.speak('Đã tắt nghe liên tục.');
      return;
    }
    if (!_commands.available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thiết bị này không hỗ trợ nhận diện giọng nói.'),
          ),
        );
      }
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cần quyền micro để điều khiển bằng giọng nói.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    _listening = false;
    setNavState(() => _alwaysOnVoice = true);
    _voice.speak('Chế độ nghe liên tục đã bật.');
    // Background always-on: a foreground service keeps the process + mic
    // alive so the wake word still works with the screen off / app minimized
    // (the STT loop runs in the main isolate, the service just keeps it up).
    unawaited(NavForegroundService.instance.startVoiceService());
    await _commands.listenAlwaysOn(
      onWake: () => _voice.speak('Nghe rồi, nói lệnh đi.'),
      onCommand: _handleCommandText,
      onPartial: _onVoicePartial,
    );
  }

  void _onVoiceResult(String text) {
    _listening = false;
    _voiceText = text;
    if (mounted) setNavState(() {});
    _showVoiceBanner(); // confirm what was heard
    _handleCommandText(text);
  }

  /// Shared command dispatch for BOTH one-shot (tap) and always-on (wake word)
  /// recognitions.
  void _handleCommandText(String text) {
    debugPrint('VOICE: recognized "$text"');
    // Always surface the heard text in the banner (also for always-on).
    _voiceText = text;
    _showVoiceBanner();
    final cmd = parseVoiceCommand(text);
    switch (cmd.type) {
      case VoiceCommandType.searchAndNavigate:
        _voiceSearchAndNavigate(cmd.query, cmd.navigate);
      case VoiceCommandType.start:
        _voice.speak('Bắt đầu chỉ đường.');
        _startNavigation();
      case VoiceCommandType.stop:
        _voice.speak('Đã dừng chỉ đường.');
        _exitNavigation();
      case VoiceCommandType.zoomIn:
        _zoomBy(1);
      case VoiceCommandType.zoomOut:
        _zoomBy(-1);
      case VoiceCommandType.voiceOn:
        setNavState(() => _voiceOn = true);
        _voice.speak('Đã bật hướng dẫn bằng giọng nói.');
      case VoiceCommandType.voiceOff:
        _voice.stop();
        setNavState(() => _voiceOn = false);
      case VoiceCommandType.alwaysOnOn:
        if (!_alwaysOnVoice) {
          _toggleAlwaysOnVoice();
        }
      case VoiceCommandType.alwaysOnOff:
        if (_alwaysOnVoice) {
          _alwaysOnVoice = false;
          _listening = false;
          _commands.stop();
          if (mounted) setNavState(() {});
          _voice.speak('Đã tắt nghe liên tục.');
        }
      case VoiceCommandType.help:
        _voice.speak(
          'Bạn có thể nói: chỉ đường tới chợ Bến Thành, bắt đầu, dừng lại, phóng to, thu nhỏ, bật tiếng, tắt tiếng, nghe luôn, hỏi AI.',
        );
      case VoiceCommandType.askAi:
        final q = cmd.query;
        if (q.isEmpty) {
          _voice.speak('Bạn muốn hỏi AI điều gì?');
          _openAiAssistant(question: null);
        } else {
          _openAiAssistant(question: q);
        }
      case VoiceCommandType.none:
        _voice.speak('Xin lỗi, tôi không hiểu lệnh.');
    }
  }
}
