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
    // Let the panel use OUR mic (shares permissions/state with the nav
    // screen) instead of spinning up its own recognizer.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => AiChatPanel(
        context: _aiContext(),
        initialQuestion: question?.trim(),
        onMicPressed: () async {
          final mic = await Permission.microphone.request();
          if (!mic.isGranted) return '';
          if (!mounted) return '';
          return _recognizeOnePhrase();
        },
      ),
    );
  }

  /// One-shot voice recognition returning the recognized phrase (or '').
  /// The window is capped (~15 s) and ALWAYS resolves — a failed session on
  /// this device (no_match) would otherwise leave the chat mic waiting forever.
  Future<String> _recognizeOnePhrase() async {
    if (!_commands.available) return '';
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
          : '${road.label.isNotEmpty ? road.label : road.highway}'
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
                'còn ${nav.meter} m',
      cameraAhead: cam == null
          ? null
          : 'Camera ${cam.camera.name} phía trước '
                '${cam.routeMeters.round()} m',
      weather: _weatherText(w),
      tripNotes: _stops.isEmpty
          ? null
          : 'Hành trình ${_stops.length} điểm dừng',
      center: _current,
    );
  }

  /// "30°C, mưa nhẹ" for the AI context (null when no weather yet).
  String? _weatherText(WeatherInfo? w) {
    if (w == null || w.tempC == null) return null;
    final cond = weatherTextForCode(w.weatherCode);
    return cond.isEmpty ? '${w.tempC}°C' : '${w.tempC}°C, $cond';
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
      _voice.speak(side.isEmpty ? 'Bạn đã đến nơi.' : 'Điểm đến$side');
      return;
    }
    final m = nav.meter;
    final speed = nav.speedMps.isFinite ? nav.speedMps : 0.0;
    // Head-up callouts are timed in SECONDS before the maneuver so they ALWAYS
    // sound ahead of the turn (never after — even with TTS + Bluetooth
    // latency): far ≈ 20 s out, near ≈ 12 s out, final ≈ 8 s out. On a long
    // straight stretch nothing repeats until the next maneuver gets close.
    final far = max(200.0, speed * 20.0); // first heads-up (20 s out)
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
    }
    if (isNew && m > far) {
      // Fresh turn → announce it immediately with its distance.
      _spokenFar = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenFar && m <= far && m > near) {
      _spokenFar = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenNear && m <= near && m > finalM) {
      _spokenNear = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenFinal && m <= finalM) {
      _spokenFinal = true;
      _voice.speak(_announce(nav, m, now: true));
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
    final into = target.isNotEmpty ? ' vào $target' : '';
    // Announce the effective speed limit of the current road (item 2) — the
    // value shown in the road-info chip. Omitted when unknown (0), so the
    // announcement never invents a limit.
    final limit = _roadInfo?.speedLimit ?? 0;
    final limitTxt = limit > 0 ? ' Tốc độ tối đa $limit km/h.' : '';
    if (now) {
      return '$verb$into.$limitTxt';
    }
    return 'Đi$onRoad, sau $m mét, $verb$into.$limitTxt';
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
    await _commands.listen(_onVoiceResult, onPartial: _onVoicePartial);
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
    _voice.speak('Đã bật nghe liên tục. Nói NavBridge để ra lệnh.');
    // Background always-on: a foreground service keeps the process + mic
    // alive so the wake word still works with the screen off / app minimized
    // (the STT loop runs in the main isolate, the service just keeps it up).
    unawaited(NavForegroundService.instance.startVoiceService());
    await _commands.listenAlwaysOn(
      onWake: () => _voice.speak('NavBridge, nghe rồi.'),
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
