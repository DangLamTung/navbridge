/// Spoken turn-by-turn guidance (Android TextToSpeech).
///
/// Audio is set to USAGE_ASSISTANCE_NAVIGATION_GUIDANCE (the same usage
/// Google Maps uses), which plays through the active media output — a
/// connected Bluetooth speaker (A2DP) when one is paired.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_tts/flutter_tts.dart';

import 'package:navbridge/services/offline_tiles.dart' show voiceVolume;

class VoiceGuide {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool get ready => _ready;

  /// Native channel that asks Android to PAUSE media during an announcement so
  /// the navigation voice isn't drowned out by YouTube / Spotify. See
  /// MainActivity.kt (navbridge/audio).
  static const MethodChannel _audioChannel = MethodChannel('navbridge/audio');

  /// Apply the persisted guidance volume (0..1). Called at init and before
  /// each utterance so a mid-ride settings change takes effect immediately.
  Future<void> _applyVolume() async {
    try {
      await _tts.setVolume(voiceVolume.clamp(0.0, 1.0));
    } catch (_) {}
  }

  Future<void> init() async {
    try {
      await _tts.setLanguage('vi-VN');
      await _tts.setSpeechRate(0.55); // fast enough to finish before the turn
      await _tts.setPitch(1.0);
      await _applyVolume();
      // Core engine is ready — optional audio attributes below must never
      // kill the voice (some devices throw on these).
      _ready = true;
      try {
        // Navigation usage → media stream → Bluetooth speaker when connected.
        await _tts.setAudioAttributesForNavigation();
      } catch (_) {}
      try {
        await _tts.setSharedInstance(true);
      } catch (_) {}
      try {
        // When an utterance finishes, release the paused media focus so
        // YouTube / radio resumes where it left off.
        _tts.setCompletionHandler(_releaseMediaFocus);
      } catch (_) {}
      debugPrint('VOICE: TTS ready (vi-VN, navigation audio)');
    } catch (e) {
      debugPrint('VOICE: TTS init failed: $e');
    }
  }

  Future<void> speak(String text) async {
    if (!_ready || text.isEmpty) return;
    try {
      await _tts.stop();
      await _applyVolume();
      await _pauseMedia();
      await _tts.speak(text);
      debugPrint('VOICE: speak "$text"');
    } catch (e) {
      debugPrint('VOICE: speak failed: $e');
    }
  }

  /// Speak [text] by QUEUEING it behind anything currently playing (for the
  /// AI assistant reading a long answer aloud sentence-by-sentence). Unlike
  /// [speak] it does NOT interrupt the current utterance, so streaming
  /// sentences flow naturally one after another. Call [stop] to flush.
  Future<void> speakQueued(String text) async {
    if (!_ready || text.isEmpty) return;
    try {
      await _tts.setQueueMode(1); // 1 = add to queue, don't interrupt
      await _applyVolume();
      await _pauseMedia();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('VOICE: speakQueued failed: $e');
    }
  }

  /// Ask Android to PAUSE media for the announcement.
  Future<void> _pauseMedia() async {
    try {
      await _audioChannel.invokeMethod('pause');
    } catch (_) {}
  }

  /// Release the paused media focus after the utterance finishes.
  Future<void> _releaseMediaFocus() async {
    try {
      await _audioChannel.invokeMethod('resume');
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
