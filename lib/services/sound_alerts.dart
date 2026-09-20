/// Native sound effects and pre-recorded voice alerts.
///
/// Plays audio assets directly on Android's USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
/// stream via the native MainActivity channel. Provides studio-quality speed
/// limit announcements and navigation earcons with zero TTS latency.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'package:navbridge/core/settings.dart' show voicePack;
import 'package:navbridge/services/voice_guide.dart' show VoiceGuide;

/// A selectable pre-recorded voice pack. [id] is the folder under
/// `assets/audio/` (empty id = system TTS, no pre-recorded clips). The
/// speed-limit announcement returns false when the pack is empty so the
/// caller falls back to the system TTS.
class VoicePackDef {
  final String id;
  final String label;
  const VoicePackDef(this.id, this.label);
}

/// Bundled voice packs offered in Settings → "Giọng nói". The first entry
/// (empty id) means "use the system TTS for everything"; the rest are
/// pre-recorded .mp3 packs under `assets/audio/<id>/`.
///
/// `voice_vn_fast` is a MERGED pack: the Waze mod ships four Vietnamese speed
/// packs (`voice`, `voice_short`, `voice_waze`, `voice_thai_ngoc_bich`) and the
/// shortest clip differs per phrase, so tools/build_voice_pack_vn.py picks the
/// fastest one for each. Total speech drops 119.8 s → 103.0 s, and the overspeed
/// warning (the one that fires while driving) goes 2.74 s → 1.63 s.
const List<VoicePackDef> kVoicePacks = [
  VoicePackDef('', 'Hệ thống (TTS) — không dùng giọng đọc sẵn'),
  VoicePackDef('voice_vn_fast', 'Tiếng Việt (nhanh) — giọng đọc sẵn'),
  VoicePackDef('voice_thai_ngoc_bich', 'Thái Ngọc Bích (chậm hơn)'),
];

class SoundAlerts {
  static final SoundAlerts instance = SoundAlerts._();
  SoundAlerts._();

  static const MethodChannel _audioChannel = MethodChannel('navbridge/audio');

  /// Supported discrete speed limits in the Thai Ngoc Bich voice pack.
  static const Set<int> supportedLimits = {
    10, 20, 30, 35, 40, 50, 60, 70, 80, 90, 100, 110, 120,
  };

  /// Play an audio asset path (e.g. `assets/audio/common/beepbeep.mp3`).
  Future<bool> play(String assetPath) async {
    try {
      final ok = await _audioChannel.invokeMethod<bool>('playAsset', {
        'asset': assetPath,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('SOUND: playAsset failed for $assetPath: $e');
      return false;
    }
  }

  /// Warning chime before camera or road hazard.
  Future<bool> playBeepBeep() => play('assets/audio/common/beepbeep.mp3');

  /// Tone sounded immediately when vehicle exceeds posted speed limit.
  Future<bool> playSpeedAlarm() => play('assets/audio/common/speed_limit.mp3');

  /// Arrival celebration fanfare when reaching the trip destination.
  Future<bool> playArrival() => play('assets/audio/common/waze_to_goal.mp3');

  /// Earcon tone when voice command listening starts.
  Future<bool> playMicStart() => play('assets/audio/common/rec_start.mp3');

  /// Earcon tone when voice command listening ends.
  Future<bool> playMicEnd() => play('assets/audio/common/rec_end.mp3');

  /// Studio Vietnamese speed limit announcement (e.g.
  /// "Tốc độ giới hạn hiện tại là 50 km/h").
  ///
  /// Queued through [VoiceGuide.speakClip] — the SAME queue as the TTS
  /// sentences — so a clip never starts on top of a sentence (or another
  /// clip) and always plays to the end. Returns false (→ caller falls back to
  /// system TTS) if the pack is disabled or the limit has no clip.
  Future<bool> playCurrentSpeedLimit(int limit) async {
    if (voicePack.isEmpty || !supportedLimits.contains(limit)) return false;
    final asset = 'assets/audio/$voicePack/current_speed_$limit.mp3';
    return VoiceGuide.instance.speakClip(
      asset,
      priority: VoiceGuide.priorityHigh,
    );
  }

  /// Studio Vietnamese next speed limit announcement.
  Future<bool> playNextSpeedLimit(int limit) async {
    if (voicePack.isEmpty || !supportedLimits.contains(limit)) return false;
    final asset = 'assets/audio/$voicePack/next_speed_$limit.mp3';
    return VoiceGuide.instance.speakClip(
      asset,
      priority: VoiceGuide.priorityHigh,
    );
  }

  /// Overspeed warning ("Bạn đang chạy quá tốc độ!"). High priority: it
  /// preempts anything that is not itself a safety announcement.
  Future<bool> playOverSpeed() async {
    if (voicePack.isEmpty) return false;
    return VoiceGuide.instance.speakClip(
      'assets/audio/$voicePack/over_speed_limit.mp3',
      priority: VoiceGuide.priorityHigh,
    );
  }
}
