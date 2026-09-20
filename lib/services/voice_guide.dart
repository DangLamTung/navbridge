/// Spoken turn-by-turn guidance (Android TextToSpeech).
///
/// Audio is set to USAGE_ASSISTANCE_NAVIGATION_GUIDANCE (the same usage
/// Google Maps uses), which plays through the active media output — a
/// connected Bluetooth speaker (A2DP) when one is paired.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_tts/flutter_tts.dart';

import 'package:navbridge/core/settings.dart'
    show ttsVoiceName, ttsVoiceLocale, voiceBoostMax, ttsSpeechRate, ttsPitch;
import 'package:navbridge/services/offline_tiles.dart' show voiceVolume;

/// What kind of announcement a queue entry is.
enum _AnnKind { tts, clip }

/// One queued announcement — either a TTS sentence or a pre-recorded clip.
class _Announcement {
  final _AnnKind kind;
  final String? text; // TTS sentence
  final String? asset; // clip path, e.g. assets/audio/voice_vn_fast/...mp3
  final int priority;
  const _Announcement._(this.kind, this.text, this.asset, this.priority);
  factory _Announcement.tts(String text, int priority) =>
      _Announcement._(_AnnKind.tts, text, null, priority);
  factory _Announcement.clip(String asset, int priority) =>
      _Announcement._(_AnnKind.clip, null, asset, priority);

  /// Two announcements are "the same" when they would say identical audio —
  /// used to drop immediate repeats (a sign announced on two consecutive GPS
  /// fixes) instead of queueing them twice.
  bool sameAs(_Announcement o) =>
      kind == o.kind && text == o.text && asset == o.asset;

  String get label => kind == _AnnKind.tts ? (text ?? '') : (asset ?? '');
}

class VoiceGuide {
  /// Single shared instance so the settings page and the nav page both talk
  /// to the same TTS engine (voice list, voice selection, speech).
  static final VoiceGuide instance = VoiceGuide._();

  VoiceGuide._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool get ready => _ready;

  /// Test hook: mark the engine ready without a platform TTS engine, so the
  /// announcement queue can be exercised in unit tests.
  @visibleForTesting
  void debugSetReady(bool value) => _ready = value;

  /// Priority levels for [speak]. A higher-priority message may interrupt a
  /// lower-priority one, but a lower-priority message never cuts off a
  /// higher-priority one that is still being spoken (e.g. a sign / camera must
  /// not interrupt the upcoming-turn announcement).
  static const int priorityLow = 0; // AI assistant
  static const int priorityNormal = 1; // signs / cameras
  static const int priorityHigh = 2; // overspeed / limit-change / prohibition
  static const int priorityCritical = 3; // turn maneuver / arrival

  // ---------------------------------------------------------------------------
  // Announcement queue — guarantees every sentence finishes
  // ---------------------------------------------------------------------------
  //
  // BOTH the TTS sentences and the pre-recorded voice clips go through ONE
  // serialized queue. Before this, three separate things broke that:
  //   * `speak()` called `_tts.stop()` first, so a second message killed the
  //     first mid-word;
  //   * `SoundAlerts` played clips on its own MediaPlayer with no coordination,
  //     so a clip overlapped a sentence (and another clip);
  //   * Dart's `playAsset` returned at `start()`, not at completion, so nothing
  //     knew when a clip had actually finished.
  //
  // Ordering rules:
  //   * idle           -> play immediately
  //   * a message at [priorityHigh] or above ARRIVING WHILE something plays
  //     preempts it — an overspeed / prohibition alert must not wait behind a
  //     weather notice;
  //   * anything else  -> queued; the running message always plays to the end.
  final List<_Announcement> _queue = <_Announcement>[];
  _Announcement? _current;
  bool _draining = false;
  int _gen = 0;

  /// True while an announcement is playing.
  bool get speaking => _current != null;

  /// How many announcements are still waiting behind the current one.
  int get pending => _queue.length;

  /// Priority of the announcement currently playing (or [priorityNormal]).
  int get activePriority => _current?.priority ?? priorityNormal;

  /// Queue cap — drop the OLDEST queued item on a burst. A stale announcement
  /// is worse than a dropped one.
  static const int _maxQueued = 6;

  /// Longest one announcement may block the queue before we give up waiting for
  /// its completion callback, so a stuck handler can never wedge the voice.
  static const Duration _itemTimeout = Duration(seconds: 30);

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
      await _tts.setSpeechRate(ttsSpeechRate.clamp(0.0, 1.0));
      await _tts.setPitch(ttsPitch.clamp(0.5, 2.0));
      await _applyVolume();
      // Prefer the user-picked voice ("Giọng đọc") if one is selected;
      // otherwise fall back to the engine's default Vietnamese voice.
      await _applySavedVoice();
      // Make `speak()` resolve only when the utterance has actually FINISHED,
      // so the announcement queue can wait for it instead of guessing (and so
      // the next sentence never starts on top of this one).
      try {
        await _tts.awaitSpeakCompletion(true);
      } catch (_) {}
      // Our own queue owns ordering; never let the engine queue too, or a
      // later speak() would silently flush something we still expect to play.
      try {
        await _tts.setQueueMode(0);
      } catch (_) {}
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

  /// Speak [text]. By default this QUEUES behind whatever is playing, so the
  /// running sentence always finishes. Only a message at [priorityHigh] or
  /// above interrupts one already in progress.
  Future<void> speak(String text, {int priority = priorityNormal}) async {
    if (!_ready || text.isEmpty) return;
    _enqueue(_Announcement.tts(text, priority));
  }

  /// Play a pre-recorded voice clip (`assets/audio/...`) through the SAME queue
  /// as TTS, so a clip and a sentence can never overlap. Used by [SoundAlerts]
  /// for the speed-limit announcements. Returns false when the voice engine is
  /// not ready, so the caller can fall back to the system TTS.
  Future<bool> speakClip(String asset, {int priority = priorityNormal}) async {
    if (!_ready || asset.isEmpty) return false;
    _enqueue(_Announcement.clip(asset, priority));
    return true;
  }

  /// Add to the queue, or start immediately when idle.
  void _enqueue(_Announcement a) {
    // Never repeat something that is playing or already waiting.
    final cur = _current;
    if (cur != null && cur.sameAs(a)) return;
    if (_queue.any((q) => q.sameAs(a))) return;

    if (cur == null) {
      _queue.add(a);
      unawaited(_drain());
      return;
    }
    // Safety first: a high-priority alert may interrupt what is playing.
    if (a.priority >= priorityHigh && a.priority > cur.priority) {
      debugPrint('VOICE: preempt "${cur.label}" with "${a.label}"');
      _gen++; // invalidate the running item so the loop does not clear _current
      _queue.insert(0, a);
      unawaited(_interrupt());
      return;
    }
    // Otherwise let the current announcement finish.
    if (_queue.length >= _maxQueued) _queue.removeAt(0);
    _queue.add(a);
  }

  /// Stop whatever is playing right now (preemption or [stop]).
  Future<void> _interrupt() async {
    try {
      await _tts.stop();
    } catch (_) {}
    try {
      await _audioChannel.invokeMethod('stopAsset');
    } catch (_) {}
  }

  /// Play queued announcements one at a time, each to completion.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_queue.isNotEmpty) {
      final a = _queue.removeAt(0);
      _current = a;
      final gen = ++_gen;
      await _play(a);
      if (gen == _gen) _current = null;
    }
    _draining = false;
    _current = null;
    await _releaseMediaFocus();
  }

  /// Play ONE announcement and return when it has finished (or was stopped).
  Future<void> _play(_Announcement a) async {
    try {
      await _applyVolume();
      await _pauseMedia();
      await _boostVolume();
      if (a.kind == _AnnKind.clip) {
        debugPrint('VOICE: clip "${a.asset}" (p${a.priority})');
        // `wait: true` resolves when the clip actually ends, so the queue
        // cannot start the next announcement on top of this one.
        await _audioChannel
            .invokeMethod('playAsset', {'asset': a.asset, 'wait': true})
            .timeout(_itemTimeout, onTimeout: () => null);
      } else {
        debugPrint('VOICE: speak "${a.text}" (p${a.priority})');
        await _tts.speak(a.text!).timeout(_itemTimeout, onTimeout: () {
          return null;
        });
      }
    } catch (e) {
      debugPrint('VOICE: play failed for "${a.label}": $e');
    }
  }

  /// Speak [text] by QUEUEING it behind anything currently playing (for the
  /// AI assistant reading a long answer aloud sentence-by-sentence). Now just a
  /// low-priority enqueue into the shared queue. Call [stop] to flush.
  Future<void> speakQueued(String text) async {
    if (!_ready || text.isEmpty) return;
    _enqueue(_Announcement.tts(text, priorityLow));
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

  /// Stop the current announcement AND flush everything queued.
  Future<void> stop() async {
    _queue.clear();
    _gen++; // invalidate the running item
    _current = null;
    await _interrupt();
    await _releaseMediaFocus();
  }

  /// Apply the persisted speech rate & pitch. Called at init and whenever the
  /// driver changes them in Settings, so a tweak takes effect immediately.
  Future<void> applySpeech() async {
    try {
      await _tts.setSpeechRate(ttsSpeechRate.clamp(0.0, 1.0));
      await _tts.setPitch(ttsPitch.clamp(0.5, 2.0));
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
