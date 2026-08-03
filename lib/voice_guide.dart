/// Spoken turn-by-turn guidance (Android TextToSpeech).
///
/// Audio is set to USAGE_ASSISTANCE_NAVIGATION_GUIDANCE (the same usage
/// Google Maps uses), which plays through the active media output — a
/// connected Bluetooth speaker (A2DP) when one is paired.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class VoiceGuide {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool get ready => _ready;

  Future<void> init() async {
    try {
      await _tts.setLanguage('vi-VN');
      await _tts.setSpeechRate(0.5); // slightly slower, clearer
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Navigation usage → media stream → Bluetooth speaker when connected.
      await _tts.setAudioAttributesForNavigation();
      await _tts.setSharedInstance(true);
      _ready = true;
      debugPrint('VOICE: TTS ready (vi-VN, navigation audio)');
    } catch (e) {
      debugPrint('VOICE: TTS init failed: $e');
    }
  }

  Future<void> speak(String text) async {
    if (!_ready || text.isEmpty) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
      debugPrint('VOICE: speak "$text"');
    } catch (e) {
      debugPrint('VOICE: speak failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
