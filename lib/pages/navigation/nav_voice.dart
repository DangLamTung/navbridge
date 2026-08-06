part of 'navigation_page.dart';

extension _NavVoice on _NavigationPageState {

  void _maybeSpeakManeuver(NavProgress nav) {
    if (!_voiceOn || !_voice.ready) return;
    if (nav.iconCode == iconArrive) {
      if (_arrivedSpoken) return;
      _arrivedSpoken = true;
      _voice.speak('Bạn đã đến nơi.');
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
    // Announce the street you turn INTO (the upcoming step's road), not the
    // current one — "rẽ trái vào <incoming street>". Falls back to the
    // current road only when the next street is unknown (e.g. arrival).
    final target = nav.nextText.isNotEmpty ? nav.nextText : nav.text;
    final road = target.isNotEmpty ? ' vào $target' : '';
    return now ? '$verb$road' : 'Sau $m mét, $verb$road';
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      _listening = false;
      if (mounted) setNavState(() {});
      await _commands.stop();
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
    setNavState(() => _listening = true);
    await _commands.listen(_onVoiceResult);
  }
  void _onVoiceResult(String text) {
    _listening = false;
    if (mounted) setNavState(() {});
    debugPrint('VOICE: recognized "$text"');
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
      case VoiceCommandType.help:
        _voice.speak(
          'Bạn có thể nói: chỉ đường tới chợ Bến Thành, bắt đầu, dừng lại, phóng to, thu nhỏ, bật tiếng, tắt tiếng.',
        );
      case VoiceCommandType.none:
        _voice.speak('Xin lỗi, tôi không hiểu lệnh.');
    }
  }
}
