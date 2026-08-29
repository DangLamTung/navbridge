/// Voice commands: Android speech recognition + a small Vietnamese/English
/// command parser ("chỉ đường tới chợ Bến Thành", "dừng lại", "phóng to"…).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'offline_tiles.dart' show ridingMode, wakeWord;

enum VoiceCommandType {
  searchAndNavigate,
  start,
  stop,
  zoomIn,
  zoomOut,
  voiceOn,
  voiceOff,
  alwaysOnOn,
  alwaysOnOff,
  help,
  askAi,
  none,
}

class VoiceCommand {
  final VoiceCommandType type;

  /// Place name to look up (for [VoiceCommandType.searchAndNavigate]).
  final String query;

  /// True for "chỉ đường tới X" (auto-start navigation), false for plain
  /// "tìm X" (only search + build the route).
  final bool navigate;

  const VoiceCommand(this.type, [this.query = '', this.navigate = false]);
}

/// Keyword parser (Vietnamese first, English fallback).
VoiceCommand parseVoiceCommand(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return const VoiceCommand(VoiceCommandType.none);

  final nav = RegExp(
    r'^(chỉ đường tới|chỉ đường đến|chỉ đường|đi đến|đi tới|navigate to|go to|take me to|direction to)\b',
  );
  final search = RegExp(r'^(tìm kiếm|tìm|search for|search)\b');
  if (nav.hasMatch(s)) {
    return VoiceCommand(
      VoiceCommandType.searchAndNavigate,
      s.substring(nav.stringMatch(s)!.length).trim(),
      true, // navigate → auto-start after building the route
    );
  }
  if (search.hasMatch(s)) {
    return VoiceCommand(
      VoiceCommandType.searchAndNavigate,
      s.substring(search.stringMatch(s)!.length).trim(),
    );
  }
  if (RegExp(r'^(bắt đầu|đi thôi|start|begin)\b').hasMatch(s)) {
    return const VoiceCommand(VoiceCommandType.start);
  }
  // Always-on wake-word toggles. These must be checked BEFORE the generic
  // "dừng/stop" pattern: "dừng nghe" / "tắt nghe luôn" would otherwise be
  // parsed as stop.
  if (s.contains('tắt nghe') ||
      s.contains('ngừng nghe') ||
      s.contains('dừng nghe')) {
    return const VoiceCommand(VoiceCommandType.alwaysOnOff);
  }
  if (s.contains('nghe liên tục') ||
      s.contains('nghe luôn') ||
      s.contains('nghe suốt')) {
    return const VoiceCommand(VoiceCommandType.alwaysOnOn);
  }
  if (RegExp(
    r'^(dừng|dừng lại|hủy|hủy bỏ|thoát|kết thúc|stop|cancel|quit|end)\b',
  ).hasMatch(s)) {
    return const VoiceCommand(VoiceCommandType.stop);
  }
  if (s.contains('phóng to') || s.contains('zoom in')) {
    return const VoiceCommand(VoiceCommandType.zoomIn);
  }
  if (s.contains('thu nhỏ') || s.contains('zoom out')) {
    return const VoiceCommand(VoiceCommandType.zoomOut);
  }
  // Check "unmute" BEFORE "mute": "unmute" contains the substring "mute",
  // so the off-check must not run first.
  if (s.contains('unmute') || s.contains('bật tiếng') || s.contains('bật âm')) {
    return const VoiceCommand(VoiceCommandType.voiceOn);
  }
  if (s.contains('tắt tiếng') || s.contains('im lặng') || s.contains('mute')) {
    return const VoiceCommand(VoiceCommandType.voiceOff);
  }
  if (s.contains('giúp') || s.contains('help')) {
    return const VoiceCommand(VoiceCommandType.help);
  }
  // AI assistant: "hỏi AI …" / "hỏi trợ lý …" / "hỏi …" / "ask ai …". The
  // rest of the phrase is the question handed to the assistant.
  //
  // NOTE: avoid `\b` after Vietnamese text — Dart's regex `\b` is ASCII-based,
  // so it never sees "ý" as a word char and the longer "hỏi trợ lý" prefix
  // fails (falling back to "hỏi"). Match explicit prefixes, longest first,
  // without a trailing word boundary.
  final aiPrefixes = ['hỏi trợ lý', 'hỏi ai', 'hỏi', 'ask ai', 'ask'];
  for (final p in aiPrefixes) {
    if (s.startsWith(p)) {
      return VoiceCommand(VoiceCommandType.askAi, s.substring(p.length).trim());
    }
  }
  return const VoiceCommand(VoiceCommandType.none);
}

/// Speech recognizer wrapper (on-device Android speech).
class VoiceCommands {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _available = false;
  bool _listening = false;
  bool _vi = false;

  // Always-on wake-word state.
  bool _alwaysOn = false;
  bool _primed = false; // wake word heard → next utterance is the command
  Timer? _restartTimer;
  void Function(String)? _onCommand;
  void Function()? _onWake;
  void Function(String)? _onPartial;

  /// Wake word matcher. Returns the command text AFTER the wake word, or null
  /// when the phrase has no wake word. The wake word is user-configurable
  /// (default "dậy đi"). Matching is DIACRITIC-INSENSITIVE + space-insensitive
  /// so the recognizer's unaccented transcription ("day di") still matches
  /// the configured "dậy đi".
  static String? _wakeCommand(String text) {
    final norm = _norm(text);
    final ww = _norm(wakeWord);
    if (ww.isNotEmpty && norm.startsWith(ww)) {
      return norm.substring(ww.length).trim();
    }
    return null;
  }

  /// Normalize for wake-word matching: lowercase, strip Vietnamese diacritics
  /// (recognizers often return "day di" for "dậy đi"), drop spaces/dashes.
  static String _norm(String s) {
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      b.write(_viMap[ch] ?? ch);
    }
    return b.toString().replaceAll(RegExp(r'[\s\-]'), '');
  }

  /// Vietnamese → ASCII accent map (tone marks + đ).
  static const Map<String, String> _viMap = {
    'à': 'a',
    'á': 'a',
    'ả': 'a',
    'ã': 'a',
    'ạ': 'a',
    'ă': 'a',
    'ằ': 'a',
    'ắ': 'a',
    'ẳ': 'a',
    'ẵ': 'a',
    'ặ': 'a',
    'â': 'a',
    'ầ': 'a',
    'ấ': 'a',
    'ẩ': 'a',
    'ẫ': 'a',
    'ậ': 'a',
    'è': 'e',
    'é': 'e',
    'ẻ': 'e',
    'ẽ': 'e',
    'ẹ': 'e',
    'ê': 'e',
    'ề': 'e',
    'ế': 'e',
    'ể': 'e',
    'ễ': 'e',
    'ệ': 'e',
    'ì': 'i',
    'í': 'i',
    'ỉ': 'i',
    'ĩ': 'i',
    'ị': 'i',
    'ò': 'o',
    'ó': 'o',
    'ỏ': 'o',
    'õ': 'o',
    'ọ': 'o',
    'ô': 'o',
    'ồ': 'o',
    'ố': 'o',
    'ổ': 'o',
    'ỗ': 'o',
    'ộ': 'o',
    'ơ': 'o',
    'ờ': 'o',
    'ớ': 'o',
    'ở': 'o',
    'ỡ': 'o',
    'ợ': 'o',
    'ù': 'u',
    'ú': 'u',
    'ủ': 'u',
    'ũ': 'u',
    'ụ': 'u',
    'ư': 'u',
    'ừ': 'u',
    'ứ': 'u',
    'ử': 'u',
    'ữ': 'u',
    'ự': 'u',
    'ỳ': 'y',
    'ý': 'y',
    'ỷ': 'y',
    'ỹ': 'y',
    'ỵ': 'y',
    'đ': 'd',
  };

  bool get available => _available;
  bool get listening => _listening;
  bool get alwaysOn => _alwaysOn;

  Future<bool> init({void Function(String status)? onStatus}) async {
    try {
      _available = await _speech.initialize(
        onStatus: (s) {
          // IMPORTANT: 'done' / 'notListening' fire when EACH short recognizer
          // session ends — on the itel that's ~1 s of silence. They must NOT
          // clear [_listening]: the one-shot [listen] loop bridges those gaps
          // by restarting the session, and clearing the flag here would kill
          // that loop after the first ~1 s → "it doesn't listen anything".
          // Only a hard 'error' frees the mic (the loop would just churn on a
          // broken recognizer). [stop] / a delivered result end the loop.
          if (s == 'error') {
            _listening = false;
          }
          onStatus?.call(s);
        },
        onError: (e) {
          debugPrint('VOICE: stt error ${e.errorMsg}');
          _listening = false;
        },
      );
      try {
        final ls = await _speech.locales();
        _vi = ls.any((l) => l.localeId.toLowerCase().startsWith('vi'));
      } catch (_) {}
      debugPrint('VOICE: speech available=$_available vi=$_vi');
    } catch (e) {
      debugPrint('VOICE: stt init failed: $e');
    }
    return _available;
  }

  /// Recognizer options tuned for the current context:
  /// - NORMAL: free-form `confirmation` model (natural sentences), short
  ///   silence (~0.8 s) so commands are snappy.
  /// - RIDING (motorbike): the short-command `search` model (more robust to
  ///   wind/engine noise on short phrases), LONGER silence tolerance
  ///   (~3 s) so a wind burst between words never finalizes the command
  ///   mid-phrase, a longer listen window, and the Bluetooth headset mic is
  ///   used when paired (Bluetooth stays enabled — the app has
  ///   BLUETOOTH_CONNECT).
  ///
  /// IMPORTANT: `onDevice: false` (network recognition via Google services)
  /// — the low-end itel's ON-DEVICE Vietnamese model returns
  /// `error_no_match`/`error_speech_timeout` for clear speech, so the cloud
  /// recognizer (the device has Google Play Services) is far more accurate.
  stt.SpeechListenOptions _listenOptions() => stt.SpeechListenOptions(
    localeId: _vi ? 'vi_VN' : null,
    onDevice: false,
    listenMode: ridingMode
        ? stt.ListenMode.search
        : stt.ListenMode.confirmation,
    partialResults: true,
    cancelOnError: true,
    // VAD silence detection: after the driver stops speaking, this much
    // silence finalizes the result. RIDING uses a much longer pause so a
    // wind burst / engine gap between words can't cut the command short;
    // NORMAL stays short so commands feel instant.
    // MINIMUM 20 s listen window in BOTH modes — the itel's recognizer tries
    // to bail after ~1 s, so we force it to keep the mic open.
    listenFor: const Duration(seconds: 30),
    pauseFor: ridingMode
        ? const Duration(milliseconds: 4000)
        : const Duration(milliseconds: 2500),
  );

  /// One-shot listen (tap the mic): returns one phrase. [onPartial] fires
  /// with the LIVE (in-progress) transcript so the UI can show a
  /// "listening… (text)" banner while the user speaks; [onResult] fires once
  /// with the final recognized phrase.
  ///
  /// The recognition keeps running until the driver taps the mic again to
  /// stop, OR VAD silence (mode-dependent: ~0.8 s normal / ~3 s riding)
  /// finalizes the result. The device's recognizer ends empty sessions after
  /// ~1 s (itel's "AiAi" service), so the session auto-restarts to bridge the
  /// gap — up to a 60 s safety cap so it can never run forever.
  Future<void> listen(
    void Function(String recognized) onResult, {
    void Function(String partial)? onPartial,
    Duration? budget,
  }) async {
    if (!_available) return;
    final deadline = DateTime.now().add(budget ?? const Duration(seconds: 60));
    _listening = true;
    var keepGoing = true;
    // `_listening` is also cleared by [stop] — the loop breaks when the
    // driver taps the mic again to cancel.
    while (keepGoing && _listening && DateTime.now().isBefore(deadline)) {
      final delivered = await _listenSession(onResult, onPartial);
      if (delivered) {
        keepGoing = false;
      } else if (DateTime.now().isBefore(deadline)) {
        // No final result yet → restart the window so the mic stays live.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    _listening = false;
  }

  /// One recognizer session. Completes true when a usable final result was
  /// delivered to [onResult]; false when the session ended without one (the
  /// device's ~1 s no-speech timeout / error / done) so the caller restarts.
  Future<bool> _listenSession(
    void Function(String recognized) onResult,
    void Function(String partial)? onPartial,
  ) async {
    final delivered = Completer<bool>();
    try {
      debugPrint(
        'VOICE: listen start mode=${ridingMode ? "search" : "confirmation"} '
        'onDevice=false vi=$_vi',
      );
      await _speech.listen(
        onResult: (r) {
          if (r.recognizedWords.isNotEmpty) {
            if (!r.finalResult) {
              onPartial?.call(r.recognizedWords);
            } else {
              onResult(r.recognizedWords);
              if (!delivered.isCompleted) delivered.complete(true);
            }
          }
        },
        listenOptions: _listenOptions(),
      );
      if (!delivered.isCompleted) delivered.complete(false);
    } catch (e) {
      debugPrint('VOICE: listen failed: $e');
      if (!delivered.isCompleted) delivered.complete(false);
    }
    return delivered.future;
  }

  /// Start ALWAYS-ON wake-word listening. Keeps the recognizer running in a
  /// loop; [onWake] fires when just the wake word is heard (we then treat the
  /// next utterance as the command), [onCommand] fires with the command text
  /// (wake word stripped). [onPartial] streams live transcript (banner).
  /// Call [stop] to turn it off.
  Future<void> listenAlwaysOn({
    required void Function(String command) onCommand,
    void Function()? onWake,
    void Function(String partial)? onPartial,
  }) async {
    if (!_available) return;
    debugPrint('VOICE: always-on enabled (wake word = nav)');
    _alwaysOn = true;
    _primed = false;
    _onCommand = onCommand;
    _onWake = onWake;
    _onPartial = onPartial;
    await _startAlwaysOnSession();
  }

  Future<void> _startAlwaysOnSession() async {
    if (!_alwaysOn || _listening) return;
    _listening = true;
    try {
      await _speech.listen(
        onResult: (r) {
          if (r.recognizedWords.isEmpty) return;
          if (!r.finalResult) {
            _onPartial?.call(r.recognizedWords);
            // Wake word may appear in partials on this device — prime/ack as
            // soon as it's heard instead of waiting (often never) for a final.
            _tryAlwaysOn(r.recognizedWords, isPartial: true);
            return;
          }
          _tryAlwaysOn(r.recognizedWords);
        },
        listenOptions: _listenOptions(),
      );
      // The recognizer session ended — either a final result, a silence
      // timeout, or a silent error (no_match on this device). ALWAYS restart
      // so the wake word keeps listening; otherwise the loop dies after one
      // session and "nav" is never heard.
      _restartTimer?.cancel();
      _restartTimer = Timer(const Duration(milliseconds: 350), () {
        _listening = false;
        _startAlwaysOnSession();
      });
    } catch (e) {
      debugPrint('VOICE: always-on session failed: $e');
      _listening = false;
      // Resilient: retry in a moment rather than dying.
      _restartTimer?.cancel();
      _restartTimer = Timer(const Duration(seconds: 1), _startAlwaysOnSession);
    }
  }

  /// Interpret one recognized phrase (partial or final). The wake word is a
  /// simple "NavBridge": hearing it (even a partial) primes the next utterance
  /// as the command. A phrase that already contains the wake word + command is
  /// executed on the FINAL result only (partials only prime/ack, so a
  /// half-typed command like "navbridge tìm" never fires early).
  void _tryAlwaysOn(String text, {bool isPartial = false}) {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final cmd = _wakeCommand(clean);
    if (cmd != null) {
      if (cmd.isEmpty) {
        // Just the wake word → acknowledge and expect the command next.
        if (!_primed) {
          _primed = true;
          _onWake?.call();
        }
        return;
      }
      if (isPartial) return; // wait for the final result to run the command
      _primed = false;
      _onCommand?.call(cmd);
      return;
    }
    // No wake word — if we're primed, this whole phrase is the command.
    // (The wake word "dậy đi" gates commands: random speech is ignored until
    // the assistant has been woken.)
    if (isPartial) return;
    if (_primed) {
      _primed = false;
      _onCommand?.call(clean);
    }
  }

  Future<void> stop() async {
    _alwaysOn = false;
    _primed = false;
    _restartTimer?.cancel();
    _listening = false;
    try {
      await _speech.stop();
    } catch (_) {}
  }
}
