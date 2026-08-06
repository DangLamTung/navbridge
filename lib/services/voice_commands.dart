/// Voice commands: Android speech recognition + a small Vietnamese/English
/// command parser ("chỉ đường tới chợ Bến Thành", "dừng lại", "phóng to"…).
library;

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum VoiceCommandType {
  searchAndNavigate,
  start,
  stop,
  zoomIn,
  zoomOut,
  voiceOn,
  voiceOff,
  help,
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
  return const VoiceCommand(VoiceCommandType.none);
}

/// Speech recognizer wrapper (on-device Android speech).
class VoiceCommands {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _available = false;
  bool _listening = false;
  bool _vi = false;

  bool get available => _available;
  bool get listening => _listening;

  Future<bool> init({void Function(String status)? onStatus}) async {
    try {
      _available = await _speech.initialize(
        onStatus: (s) {
          // A session ends (silence / final result / error) → free the mic.
          if (s == 'done' || s == 'notListening' || s == 'error') {
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

  Future<void> listen(void Function(String recognized) onResult) async {
    if (!_available || _listening) return;
    _listening = true;
    try {
      await _speech.listen(
        onResult: (r) {
          if (r.finalResult && r.recognizedWords.isNotEmpty) {
            onResult(r.recognizedWords);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          localeId: _vi ? 'vi_VN' : null,
          onDevice: true,
          listenMode: stt.ListenMode.confirmation,
          partialResults: false,
          cancelOnError: true,
        ),
      );
    } catch (e) {
      debugPrint('VOICE: listen failed: $e');
      _listening = false;
    }
  }

  Future<void> stop() async {
    _listening = false;
    try {
      await _speech.stop();
    } catch (_) {}
  }
}
