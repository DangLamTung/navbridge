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

/// Strip Vietnamese diacritics while KEEPING word boundaries (1:1 char map),
/// for matching what the recognizer often returns without tone marks
/// ("hoi ai" for "hỏi ai"). Uses the same accent map as the wake word.
String _stripVi(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(VoiceCommands._viMap[ch] ?? ch);
  }
  return b.toString();
}

/// Natural "go to a place" prefixes, matched on the DIACRITIC-STRIPPED phrase —
/// the recognizer frequently returns "chi duong toi …" / "duong den …", and
/// drivers say "đường đến X" or just "dẫn đường X" as often as the canonical
/// "chỉ đường tới X". Longest first, so "chỉ đường tới" wins over "chỉ đường".
const List<String> _navPrefixes = [
  'chi duong toi',
  'chi duong den',
  'chi duong di',
  'chi duong ve',
  'chi duong',
  'dan duong toi',
  'dan duong den',
  'dan duong ve',
  'dan duong',
  'tim duong toi',
  'tim duong den',
  'tim duong ve',
  'tim duong',
  'duong den',
  'duong toi',
  'duong ve',
  'dua toi den',
  'dua toi toi',
  'cho toi den',
  'cho toi toi',
  'muon den',
  'muon toi',
  'navigate to',
  'go to',
  'take me to',
  'direction to',
  'drive to',
];

/// Weaker "go to" prefixes, tried LAST so they can never shadow a real command:
/// "đi thôi" is START, "dừng lại" is STOP, and "đèn đỏ …" must not become a
/// place called "đỏ …".
const List<String> _travelPrefixes = ['den ', 'toi ', 'di ', 've '];

/// Markers that make an utterance a QUESTION (the AI assistant's job) rather
/// than a destination — used only by the bare-place fallback below.
const List<String> _questionMarkers = [
  'the nao',
  'nhu the nao',
  'bao nhieu',
  'bao lau',
  'may gio',
  'khi nao',
  'tai sao',
  'vi sao',
  'lam sao',
  'the nao',
  'o dau',
  'o day',
  'co khong',
  'khong?',
  '?',
];

/// Words that mean the utterance is a COMMAND/control phrase, never a place —
/// guards the bare-place fallback.
const List<String> _controlWords = [
  'bat',
  'tat',
  'dung',
  'huy',
  'thoat',
  'ket thuc',
  'phong',
  'thu nho',
  'giup',
  'help',
  'stop',
  'cancel',
  'zoom',
  'mute',
  'unmute',
  'start',
  'bat dau',
  'begin',
  'nghe',
  'hoi',
  'ask',
];

bool _startsPhrase(String stripped, String prefix) {
  if (!stripped.startsWith(prefix)) return false;
  // A prefix ending in a space already carries its own boundary ("den "), so
  // the next character is the start of the place name, not a boundary.
  if (prefix.endsWith(' ')) return true;
  final next = stripped.length == prefix.length ? '' : stripped[prefix.length];
  return next.isEmpty || ' ,.:;!?-'.contains(next);
}

/// Keyword parser (Vietnamese first, English fallback).
VoiceCommand parseVoiceCommand(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return const VoiceCommand(VoiceCommandType.none);
  // Diacritic-stripped copy — SAME length as [s] (the map is 1:1), so a prefix
  // length measured here can cut the original phrase for the query.
  final flat = _stripVi(s);

  // "chỉ đường tới X" / "đường đến X" / "dẫn đường X" / "navigate to X" → auto
  // start navigation. Longest prefix first (the list is ordered).
  for (final p in _navPrefixes) {
    if (_startsPhrase(flat, p)) {
      return VoiceCommand(
        VoiceCommandType.searchAndNavigate,
        s.substring(p.length).trim(),
        true,
      );
    }
  }
  final search = RegExp(r'^(tim kiem|tim|search for|search)\b');
  if (search.hasMatch(flat)) {
    return VoiceCommand(
      VoiceCommandType.searchAndNavigate,
      s.substring(search.stringMatch(flat)!.length).trim(),
    );
  }
  if (RegExp(r'^(bat dau|di thoi|start|begin)\b').hasMatch(flat)) {
    return const VoiceCommand(VoiceCommandType.start);
  }
  // Always-on wake-word toggles. These must be checked BEFORE the generic
  // "dừng/stop" pattern: "dừng nghe" / "tắt nghe luôn" would otherwise be
  // parsed as stop.
  if (flat.contains('tat nghe') ||
      flat.contains('ngung nghe') ||
      flat.contains('dung nghe')) {
    return const VoiceCommand(VoiceCommandType.alwaysOnOff);
  }
  if (flat.contains('nghe lien tuc') ||
      flat.contains('nghe luon') ||
      flat.contains('nghe suot')) {
    return const VoiceCommand(VoiceCommandType.alwaysOnOn);
  }
  if (RegExp(
    r'^(dung|dung lai|huy|huy bo|thoat|ket thuc|stop|cancel|quit|end)\b',
  ).hasMatch(flat)) {
    return const VoiceCommand(VoiceCommandType.stop);
  }
  if (flat.contains('phong to') || flat.contains('zoom in')) {
    return const VoiceCommand(VoiceCommandType.zoomIn);
  }
  if (flat.contains('thu nho') || flat.contains('zoom out')) {
    return const VoiceCommand(VoiceCommandType.zoomOut);
  }
  // Check "unmute" BEFORE "mute": "unmute" contains the substring "mute",
  // so the off-check must not run first.
  if (flat.contains('unmute') ||
      flat.contains('bat tieng') ||
      flat.contains('bat am')) {
    return const VoiceCommand(VoiceCommandType.voiceOn);
  }
  if (flat.contains('tat tieng') ||
      flat.contains('im lang') ||
      flat.contains('mute')) {
    return const VoiceCommand(VoiceCommandType.voiceOff);
  }
  if (flat.contains('giup') || flat.contains('help')) {
    return const VoiceCommand(VoiceCommandType.help);
  }
  // AI assistant: "hỏi AI …" / "hỏi trợ lý …" / "hỏi …" / "ask ai …". The rest
  // of the phrase is the question handed to the assistant.
  //
  // Match against a diacritic-STRIPPED copy (the recognizer often returns
  // "hoi ai" for "hỏi ai" / "cho toi hoi" for "cho tôi hỏi"), longest prefix
  // first, WITHOUT a trailing `\b` (Dart's `\b` is ASCII-based and fails after
  // Vietnamese text). The returned query keeps the ORIGINAL phrase.
  final ai = flat;
  final aiPrefixes = [
    'cho toi hoi tro ly',
    'xin hoi tro ly',
    'lam on hoi tro ly',
    'cho toi hoi ai',
    'xin hoi ai',
    'lam on hoi ai',
    'hoi tro ly',
    'hoi ai',
    'cho toi hoi',
    'xin hoi',
    'lam on hoi',
    'hoi',
    'ask ai',
    'ask',
  ];
  for (final p in aiPrefixes) {
    if (ai.startsWith(p)) {
      // Strip the (ASCII length == original length) prefix from the original.
      return VoiceCommand(VoiceCommandType.askAi, s.substring(p.length).trim());
    }
  }
  // LAST RESORT — a bare destination: "đường Nguyễn Trãi", "chợ Bến Thành",
  // "sân bay Tân Sơn Nhất", "đến Vũng Tàu". The user: "just tell the location
  // should start the navigation". Every command above (and the wake-word
  // toggles) has already had its chance, so anything left that is NOT a
  // question and NOT a control word is treated as a place to drive to; the
  // caller searches it and can still fall back to the assistant when the search
  // finds nothing.
  if (flat.length >= 3 &&
      !_questionMarkers.any(flat.contains) &&
      !_controlWords.any((w) => _startsPhrase(flat, w))) {
    for (final p in _travelPrefixes) {
      if (_startsPhrase(flat, p)) {
        final q = s.substring(p.length).trim();
        if (q.isNotEmpty) {
          return VoiceCommand(VoiceCommandType.searchAndNavigate, q, true);
        }
      }
    }
    return VoiceCommand(VoiceCommandType.searchAndNavigate, s.trim(), true);
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

  @visibleForTesting
  static String? wakeCommand(String text) => _wakeCommand(text);

  /// Wake word matcher. Returns the command text AFTER the wake word, or null
  /// when the phrase has no wake word. The wake word is user-configurable
  /// (default "dậy đi"). Matching is DIACRITIC-INSENSITIVE + space-insensitive,
  /// but preserves the original spaces and words in the remaining command so
  /// [parseVoiceCommand] can match keywords.
  static String? _wakeCommand(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final normWw = _normWords(wakeWord);
    if (normWw.isEmpty) return null;

    final stripped = _stripVi(clean);
    final pattern = RegExp(
      r'^\s*' + normWw.map(RegExp.escape).join(r'[\s,.-]+') + r'[\s,.:;!?-]*',
      caseSensitive: false,
    );
    final m = pattern.firstMatch(stripped);
    if (m == null) return null;
    return clean.substring(m.end).trim();
  }

  /// Split [s] into diacritic-stripped, lowercase words for wake-word matching.
  static List<String> _normWords(String s) {
    final stripped = _stripVi(s);
    return stripped
        .toLowerCase()
        .split(RegExp(r'[\s,.-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
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

  void Function(String status)? _sessionStatusCallback;

  bool get available => _available;
  bool get listening => _listening;
  bool get alwaysOn => _alwaysOn;

  Future<bool> init({void Function(String status)? onStatus}) async {
    try {
      _available = await _speech.initialize(
        onStatus: (s) {
          if (s == 'error') {
            _listening = false;
          }
          _sessionStatusCallback?.call(s);
          onStatus?.call(s);
        },
        onError: (e) {
          debugPrint('VOICE: stt error ${e.errorMsg}');
          _listening = false;
          _sessionStatusCallback?.call('error');
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
  /// - NORMAL: `dictation` model with generous silence tolerance (~4 s) so
  ///   natural pauses between words do not cut the user off prematurely.
  /// - RIDING (motorbike): the short-command `search` model (more robust to
  ///   wind/engine noise on short phrases), longer silence tolerance (~7 s),
  ///   and the Bluetooth headset mic is used when paired.
  stt.SpeechListenOptions _listenOptions() => stt.SpeechListenOptions(
    localeId: _vi ? 'vi_VN' : null,
    onDevice: false,
    listenMode: ridingMode
        ? stt.ListenMode.search
        : stt.ListenMode.dictation,
    partialResults: true,
    cancelOnError: false,
    listenFor: const Duration(seconds: 45),
    pauseFor: ridingMode
        ? const Duration(milliseconds: 7000)
        : const Duration(milliseconds: 4000),
  );

  /// One-shot listen (tap the mic): returns one phrase. [onPartial] fires
  /// with the LIVE (in-progress) transcript so the UI can show a
  /// "listening… (text)" banner while the user speaks; [onResult] fires once
  /// with the final recognized phrase.
  Future<void> listen(
    void Function(String recognized) onResult, {
    void Function(String partial)? onPartial,
    Duration? budget,
  }) async {
    if (!_available) {
      final ok = await init();
      if (!ok) return;
    }
    if (_speech.isListening) {
      try {
        await _speech.stop();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } catch (_) {}
    }
    final deadline = DateTime.now().add(budget ?? const Duration(seconds: 60));
    _listening = true;
    var keepGoing = true;
    String heard = '';
    while (keepGoing && _listening && DateTime.now().isBefore(deadline)) {
      final delivered = await _listenSession(
        onResult,
        onPartial,
        onHeard: (text) => heard = text,
      );
      if (delivered) {
        keepGoing = false;
      } else if (DateTime.now().isBefore(deadline)) {
        // No final result yet → restart the window so the mic stays live.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    _listening = false;
    // Low-end itel recognizers often transcribe the phrase as PARTIALS but
    // never finalize. If the window closed with text heard but no final
    // result delivered, use the last partial so the caller doesn't say
    // "Không nghe rõ" when the text was actually transcribed.
    if (keepGoing && heard.trim().isNotEmpty) {
      onResult(heard.trim());
    }
  }

  /// One recognizer session. Awaits the actual session termination (either a
  /// final result or recognizer finish/error), never completing prematurely.
  Future<bool> _listenSession(
    void Function(String recognized) onResult,
    void Function(String partial)? onPartial, {
    void Function(String heard)? onHeard,
  }) async {
    final delivered = Completer<bool>();
    Timer? timeoutTimer;
    String lastHeard = '';

    // Deliver the best transcript we got (a final result if one arrived, else
    // the last partial) exactly once, no matter how the session ends.
    void finish() {
      if (delivered.isCompleted) return;
      if (lastHeard.trim().isNotEmpty) {
        onResult(lastHeard.trim());
        delivered.complete(true);
      } else {
        delivered.complete(false);
      }
    }

    _sessionStatusCallback = (s) {
      if (s == 'notListening' || s == 'done' || s == 'error') finish();
    };

    try {
      debugPrint(
        'VOICE: listen start mode=${ridingMode ? "search" : "dictation"} '
        'onDevice=false vi=$_vi',
      );
      final started = await _speech.listen(
        onResult: (r) {
          if (r.recognizedWords.isNotEmpty) {
            lastHeard = r.recognizedWords;
            onHeard?.call(r.recognizedWords);
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
      if (!started) finish();
      timeoutTimer = Timer(const Duration(seconds: 30), finish);
    } catch (e) {
      debugPrint('VOICE: listen failed: $e');
      finish();
    }
    final res = await delivered.future;
    timeoutTimer?.cancel();
    _sessionStatusCallback = null;
    return res;
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
    debugPrint('VOICE: always-on enabled (wake word = $wakeWord)');
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

    _sessionStatusCallback = (s) {
      if (s == 'notListening' || s == 'done' || s == 'error') {
        _listening = false;
        if (_alwaysOn) {
          _restartTimer?.cancel();
          _restartTimer = Timer(const Duration(milliseconds: 300), () {
            if (_alwaysOn) _startAlwaysOnSession();
          });
        }
      }
    };

    try {
      final started = await _speech.listen(
        onResult: (r) {
          if (r.recognizedWords.isEmpty) return;
          if (!r.finalResult) {
            _onPartial?.call(r.recognizedWords);
            _tryAlwaysOn(r.recognizedWords, isPartial: true);
            return;
          }
          _tryAlwaysOn(r.recognizedWords);
        },
        listenOptions: _listenOptions(),
      );
      if (!started) {
        _listening = false;
        if (_alwaysOn) {
          _restartTimer?.cancel();
          _restartTimer = Timer(const Duration(seconds: 1), _startAlwaysOnSession);
        }
      }
    } catch (e) {
      debugPrint('VOICE: always-on session failed: $e');
      _listening = false;
      if (_alwaysOn) {
        _restartTimer?.cancel();
        _restartTimer = Timer(const Duration(seconds: 1), _startAlwaysOnSession);
      }
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
    _sessionStatusCallback = null;
    _listening = false;
    try {
      await _speech.stop();
    } catch (_) {}
  }
}
