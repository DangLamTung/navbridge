/// Native sound effects and pre-recorded voice alerts.
///
/// Plays audio assets directly on Android's USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
/// stream via the native MainActivity channel. Provides studio-quality speed
/// limit announcements and navigation earcons with zero TTS latency.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'package:navbridge/core/settings.dart' show voicePack;
import 'package:navbridge/services/voice_guide.dart' show VoiceGuide, voiceMuted;

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
  VoicePackDef('voice_vn_hanoi_quyphai', 'Hà Nội Quý Phái (Waze Style — Gemini 3.8)'),
  VoicePackDef('voice_vn_fast', 'Tiếng Việt (nhanh) — giọng đọc sẵn'),
  // Google Cloud Text-to-Speech (Chirp 3: HD, vi-VN), built by
  // tools/build_voice_pack_gcp.py — 84.3 s of speech for the same 28 clips as
  // voice_vn_fast (103.0 s), i.e. noticeably snappier.
  VoicePackDef('voice_vn_gcp', 'Tiếng Việt (Google Cloud)'),
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
  ///
  /// Returns false while [voiceMuted] — this player is the SECOND audio path
  /// (the speed-limit clips and the chimes go straight out on the native
  /// channel, bypassing the [VoiceGuide] queue), so a mute that only covered
  /// the queue would still let "Tốc độ giới hạn hiện tại là 50 km/h" out of the
  /// speaker. A false return is also what makes the caller fall back to TTS,
  /// which is muted too — so the result is silence either way.
  Future<bool> play(String assetPath) async {
    if (voiceMuted) return false;
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

  /// Packs that ship the full catalog of road signs, cameras, and system alerts
  /// as pre-recorded studio audio.
  static const Set<String> fullCatalogPacks = {
    'voice_vn_hanoi_quyphai',
  };

  /// Map of exact Vietnamese guidance phrases to pre-recorded clip filenames.
  static const Map<String, String> phraseToClip = {
    // Road signs (nav_signs.dart)
    'Biển STOP sắp tới': 'sign_stop.mp3',
    'Biển nhường đường sắp tới': 'sign_nhuong_duong.mp3',
    'Cấm vượt sắp tới': 'sign_vao_cam_vuot.mp3',
    'Hết cấm vượt sắp tới': 'sign_ra_cam_vuot.mp3',
    'Cấm rẽ trái sắp tới': 'sign_cam_re_trai.mp3',
    'Cấm rẽ phải sắp tới': 'sign_cam_re_phai.mp3',
    'Cấm quay đầu sắp tới': 'sign_cam_quay_dau.mp3',
    'Cấm rẽ trái và quay đầu sắp tới': 'sign_cam_re_trai_quay_dau.mp3',
    'Cấm rẽ phải và quay đầu sắp tới': 'sign_cam_re_phai_quay_dau.mp3',
    'Chỉ đi thẳng sắp tới': 'sign_chi_di_thang.mp3',
    'Chỉ rẽ phải sắp tới': 'sign_chi_re_phai.mp3',
    'Chỉ rẽ trái sắp tới': 'sign_chi_re_trai.mp3',
    'Hết mọi lệnh cấm sắp tới': 'sign_het_moi_lenh_cam.mp3',
    'Giảm tốc độ sắp tới': 'sign_giam_toc_do.mp3',
    'Trạm thu phí sắp tới': 'sign_tram_thu_phi.mp3',
    'Đường ngang giao với đường sắt sắp tới': 'sign_giao_duong_sat.mp3',
    'Hầm đường bộ sắp tới': 'sign_duong_ham.mp3',
    'Cấm ô tô sắp tới': 'sign_cam_o_to.mp3',
    'Cấm xe máy sắp tới': 'sign_cam_xe_may.mp3',
    'Cấm đỗ xe sắp tới': 'sign_cam_do_xe.mp3',
    'Cấm đi thẳng sắp tới': 'sign_cam_di_thang.mp3',
    'Cấm rẽ trái và rẽ phải sắp tới': 'sign_cam_re_hai_huong.mp3',
    'Đường một chiều sắp tới': 'sign_duong_mot_chieu.mp3',
    'Làn dành riêng sắp tới': 'sign_lan_danh_rieng.mp3',
    'Đèn giao thông sắp tới': 'sign_den_giao_thong.mp3',
    'Bắt đầu khu dân cư': 'sign_vao_kdc.mp3',
    'Hết khu dân cư': 'sign_ra_kdc.mp3',
    'Bắt đầu khu dân cư phía trước': 'sign_vao_kdc_ahead.mp3',
    'Hết khu dân cư phía trước': 'sign_ra_kdc_ahead.mp3',

    // Camera alerts (nav_weather.dart)
    'Camera tốc độ phía trước': 'cam_toc_do.mp3',
    'Camera tốc độ ngay phía trước': 'cam_toc_do_ngay.mp3',
    'Camera giám sát giao thông phía trước': 'cam_giao_thong.mp3',
    'Camera giám sát giao thông ngay phía trước': 'cam_giao_thong_ngay.mp3',
    'Camera phạt nguội phía trước': 'cam_phat_nguoi.mp3',
    'Camera phạt nguội ngay phía trước': 'cam_phat_nguoi_ngay.mp3',
    'Camera đèn đỏ phía trước': 'cam_den_do.mp3',
    'Camera đèn đỏ ngay phía trước': 'cam_den_do_ngay.mp3',
    'Kiểm tra tốc độ': 'cam_kiem_tra_toc_do.mp3',

    // Navigation & system alerts
    'Đang tính lại đường': 'reroute.mp3',
    'Mất tín hiệu GPS': 'gps_lost.mp3',
    'Đã có tín hiệu GPS': 'gps_found.mp3',
    'Bạn đã đến nơi': 'arrived.mp3',
    'Điểm đến bên trái': 'arrived_left.mp3',
    'Điểm đến bên phải': 'arrived_right.mp3',
    'Giảm tốc độ! Vượt quá tốc độ.': 'warning_overspeed.mp3',
    'Bạn đang chạy quá tốc độ!': 'over_speed_limit.mp3',
    'Chú ý! Xe mô tô không được phép đi vào đường cao tốc.': 'warning_motorway.mp3',
    'Trạm dừng chân': 'tram_dung.mp3',
    'Trạm dừng cao tốc': 'tram_dung_cao_toc.mp3',
    'Rẽ trái': 'turn_left.mp3',
    'Rẽ phải': 'turn_right.mp3',
    'Rẽ trái nhẹ': 'turn_slight_left.mp3',
    'Rẽ phải nhẹ': 'turn_slight_right.mp3',
    'Đi thẳng': 'turn_straight.mp3',
    'Quay đầu': 'turn_uturn.mp3',
  };

  /// Looks up whether the active voice pack has a pre-recorded clip for [phrase].
  /// Returns the asset path if available, or null to fall back to TTS.
  static String? clipForPhrase(String phrase) {
    if (voicePack.isEmpty || !fullCatalogPacks.contains(voicePack)) return null;
    final clipName = phraseToClip[phrase.trim()];
    if (clipName == null) return null;
    return 'assets/audio/$voicePack/$clipName';
  }
}
