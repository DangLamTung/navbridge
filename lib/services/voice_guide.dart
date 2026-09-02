/// Spoken turn-by-turn guidance (Android TextToSpeech).
///
/// Audio is set to USAGE_ASSISTANCE_NAVIGATION_GUIDANCE (the same usage
/// Google Maps uses), which plays through the active media output — a
/// connected Bluetooth speaker (A2DP) when one is paired.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_tts/flutter_tts.dart';

import 'package:navbridge/core/settings.dart'
    show ttsVoiceName, ttsVoiceLocale, voiceBoostMax;
import 'package:navbridge/services/offline_tiles.dart' show voiceVolume;

class VoiceGuide {
  /// Single shared instance so the settings page and the nav page both talk
  /// to the same TTS engine (voice list, voice selection, speech).
  static final VoiceGuide instance = VoiceGuide._();

  VoiceGuide._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool get ready => _ready;

  /// Priority levels for [speak]. A higher-priority message may interrupt a
  /// lower-priority one, but a lower-priority message never cuts off a
  /// higher-priority one that is still being spoken (e.g. a sign / camera must
  /// not interrupt the upcoming-turn announcement).
  static const int priorityLow = 0; // AI assistant
  static const int priorityNormal = 1; // signs / cameras / zone
  static const int priorityHigh = 2; // overspeed / limit-change / prohibition
  static const int priorityCritical = 3; // turn maneuver / arrival

  int _activePriority = priorityNormal;
  bool _isSpeaking = false;
  int _utteranceGen = 0;

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
      // Prefer the user-picked voice ("Giọng đọc") if one is selected;
      // otherwise fall back to the engine's default Vietnamese voice.
      await _applySavedVoice();
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

  Future<void> speak(String text, {int priority = priorityNormal}) async {
    if (!_ready || text.isEmpty) return;
    // Higher priority wins: don't let a lower-priority message interrupt a
    // higher-priority one that is still being spoken.
    if (_isSpeaking && priority < _activePriority) return;
    _activePriority = priority;
    _isSpeaking = true;
    final gen = ++_utteranceGen;
    try {
      await _tts.stop();
      await _applyVolume();
      await _pauseMedia();
      await _boostVolume();
      await _tts.speak(text);
      debugPrint('VOICE: speak "$text" (p$priority)');
    } catch (e) {
      debugPrint('VOICE: speak failed: $e');
      // No utterance is playing, so the completion handler below will never
      // fire — clear the speaking state HERE or every lower-priority message
      // would be blocked forever.
      if (gen == _utteranceGen) {
        _isSpeaking = false;
        _activePriority = priorityNormal;
      }
      return;
    }
    // When THIS utterance finishes, clear the active-utterance state (only if
    // it is still the latest) and release the paused media.
    try {
      _tts.setCompletionHandler(() {
        if (gen == _utteranceGen) {
          _isSpeaking = false;
          _activePriority = priorityNormal;
        }
        _releaseMediaFocus();
      });
    } catch (_) {}
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
      await _boostVolume();
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
    try {
      await _audioChannel.invokeMethod('restore');
    } catch (_) {}
  }

  /// Raise the Android media (STREAM_MUSIC) volume to the configured cap
  /// ([voiceBoostMax]) so the nav voice is audible over engine/wind noise —
  /// but never above it, so it doesn't blast. The user's own volume is
  /// remembered and restored when the utterance finishes.
  Future<void> _boostVolume() async {
    try {
      await _audioChannel.invokeMethod('boost', {'max': voiceBoostMax});
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Applies the persisted TTS voice ([ttsVoiceName]/[ttsVoiceLocale]) if one
  /// has been selected. No-op when the user hasn't picked a voice.
  Future<void> _applySavedVoice() async {
    if (ttsVoiceName.isEmpty) return;
    try {
      await _tts.setVoice({'name': ttsVoiceName, 'locale': ttsVoiceLocale});
      debugPrint('VOICE: voice = $ttsVoiceName ($ttsVoiceLocale)');
    } catch (e) {
      debugPrint('VOICE: setVoice failed: $e');
    }
  }

  /// Lists the TTS voices the platform currently exposes (Android / iOS /
  /// macOS). Each entry is a Map with at least 'name' and 'locale'; iOS also
  /// adds 'quality', 'gender' and 'identifier'. Safe — returns [] on error.
  Future<List<Map<String, String>>> getVoices() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), '$v')))
          .toList();
    } catch (e) {
      debugPrint('VOICE: getVoices failed: $e');
      return const [];
    }
  }

  /// Applies [name]/[locale] immediately and persists it as the selected
  /// voice. Passing an empty [name] resets to the engine default. Returns
  /// false if the platform rejected the voice.
  Future<bool> selectVoice(String name, String locale) async {
    try {
      if (name.isEmpty) {
        await _tts.clearVoice();
        ttsVoiceName = '';
        ttsVoiceLocale = 'vi-VN';
        debugPrint('VOICE: voice reset to default');
        return true;
      }
      await _tts.setVoice({'name': name, 'locale': locale});
      ttsVoiceName = name;
      ttsVoiceLocale = locale;
      debugPrint('VOICE: selected voice = $name ($locale)');
      return true;
    } catch (e) {
      debugPrint('VOICE: selectVoice failed: $e');
      return false;
    }
  }
}
