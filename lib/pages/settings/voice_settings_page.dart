/// "Giọng nói" settings page — riding-mode mic tuning, wake word, guidance
/// volume and the TTS voice picker.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/settings.dart'
    show voiceBoostMax, ttsVoiceName, ttsSpeechRate, ttsPitch, voicePack;
import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show ridingMode, voiceVolume, wakeWord;
import 'package:navbridge/services/sound_alerts.dart';
import 'package:navbridge/services/voice_guide.dart';
import 'package:navbridge/ui/widgets.dart';

class VoiceSettingsPage extends StatefulWidget {
  const VoiceSettingsPage({super.key});

  @override
  State<VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends State<VoiceSettingsPage> {
  bool _ridingMode = false;
  double _voiceVolume = 1.0;
  double _ttsSpeechRate = 0.55;
  double _ttsPitch = 1.0;
  String _ttsVoiceName = '';
  String _voicePack = '';
  final _wakeWordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ridingMode = ridingMode;
    _voiceVolume = voiceVolume;
    _ttsSpeechRate = ttsSpeechRate;
    _ttsPitch = ttsPitch;
    _ttsVoiceName = ttsVoiceName;
    _voicePack = voicePack;
    _wakeWordCtrl.text = wakeWord;
  }

  @override
  void dispose() {
    _wakeWordCtrl.dispose();
    super.dispose();
  }

  /// Riding mode: tune voice recognition for a moving motorbike — short-
  /// command model, longer wind/engine silence tolerance, Bluetooth headset
  /// mic.
  Future<void> _setRidingMode(bool v) async {
    setState(() {
      _ridingMode = v;
      ridingMode = v;
    });
    await saveAllSettings();
  }

  /// Spoken guidance volume (0..1), persisted. One slider drives BOTH the TTS
  /// engine's relative volume and the media-stream boost cap.
  Future<void> _setVoiceVolume(double v) async {
    setState(() {
      _voiceVolume = v;
      voiceVolume = v;
      voiceBoostMax = v; // keep the boost cap in sync with the volume
    });
    await saveAllSettings();
    await VoiceGuide.instance.applySpeech();
  }

  /// Speech rate (0.0–1.0). Applied live to the TTS engine.
  Future<void> _setSpeechRate(double v) async {
    setState(() {
      _ttsSpeechRate = v;
      ttsSpeechRate = v;
    });
    await VoiceGuide.instance.applySpeech();
    await saveAllSettings();
  }

  /// Voice pitch (0.5–2.0). Applied live to the TTS engine.
  Future<void> _setPitch(double v) async {
    setState(() {
      _ttsPitch = v;
      ttsPitch = v;
    });
    await VoiceGuide.instance.applySpeech();
    await saveAllSettings();
  }

  /// Edit the always-on voice assistant wake word.
  Future<void> _editWakeWord() async {
    final newVal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Từ khoá đánh thức'),
        content: TextField(
          controller: _wakeWordCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ví dụ: nav, ok, hey'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () {
              _wakeWordCtrl.text = _wakeWordCtrl.text.trim();
              Navigator.of(ctx).pop(_wakeWordCtrl.text);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (newVal == null || !mounted) return;
    setState(() => wakeWord = newVal.isEmpty ? 'nav' : newVal);
    await saveAllSettings();
  }

  /// Open the "Giọng đọc" picker: list the platform's installed TTS voices
  /// (Vietnamese first) and let the user pick one.
  Future<void> _pickVoice() async {
    final voices = await VoiceGuide.instance.getVoices();
    if (!mounted) return;

    final vi = voices
        .where((v) => (v['locale'] ?? '').toLowerCase().startsWith('vi'))
        .toList();
    final others = voices
        .where((v) => !(v['locale'] ?? '').toLowerCase().startsWith('vi'))
        .toList();
    final ordered = <List<Map<String, String>>>[vi, others];

    final picked = await showModalBottomSheet<Map<String, String>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Chọn giọng đọc',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.speaker, size: 20),
                    title: const Text('Mặc định (tự động)'),
                    trailing: _ttsVoiceName.isEmpty
                        ? const Icon(Icons.check, color: kAppBlue)
                        : null,
                    onTap: () => Navigator.of(ctx).pop(<String, String>{}),
                  ),
                  for (final group in ordered)
                    for (final v in group)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.record_voice_over,
                          size: 20,
                        ),
                        title: Text(
                          (v['name'] ?? v['identifier'] ?? 'Giọng nói')
                              .toString(),
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          v['locale'] ?? '',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: _ttsVoiceName == v['name']
                            ? const Icon(Icons.check, color: kAppBlue)
                            : null,
                        onTap: () => Navigator.of(ctx).pop(v),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (picked == null || !mounted) return;

    final name = picked['name'] ?? '';
    final locale = picked['locale'] ?? 'vi-VN';
    final ok = await VoiceGuide.instance.selectVoice(name, locale);
    setState(() => _ttsVoiceName = ok ? name : _ttsVoiceName);
    await saveAllSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok && name.isNotEmpty
                ? 'Đã đổi giọng đọc: $name'
                : 'Đã trả về giọng mặc định',
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// Pick which pre-recorded voice pack to use for speed-limit / alert
  /// announcements (or system TTS). Applies immediately to [SoundAlerts].
  Future<void> _pickVoicePack() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Chọn giọng đọc sẵn (voice pack)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in kVoicePacks)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.graphic_eq, size: 20),
                      title: Text(
                        p.label,
                        style: const TextStyle(fontSize: 13),
                      ),
                      trailing: _voicePack == p.id
                          ? const Icon(Icons.check, color: kAppBlue)
                          : null,
                      onTap: () => Navigator.of(ctx).pop(p.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _voicePack = picked);
    voicePack = picked;
    await saveAllSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            picked.isEmpty
                ? 'Đã dùng giọng hệ thống (TTS)'
                : 'Đã chọn giọng đọc sẵn: ${kVoicePacks.firstWhere((p) => p.id == picked).label}',
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Giọng nói',
      children: [
        const SettingsSection('Nhập liệu giọng nói'),
        SettingsCard(
          child: Column(
            children: [
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Chế độ đi xe máy (chống gió)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Nhận diện giọng nói khoan dung với tiếng gió / máy nổ '
                  'và dùng micro tai nghe Bluetooth khi có.',
                  style: TextStyle(fontSize: 11),
                ),
                value: _ridingMode,
                onChanged: _setRidingMode,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.record_voice_over,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Từ khoá đánh thức (wake word)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Nói từ này để gọi trợ lý khi bật "nghe liên tục". Mặc định '
                  '"nav" — đổi nếu máy không nhận.',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: Text(
                  '"${_wakeWordCtrl.text.isEmpty ? wakeWord : _wakeWordCtrl.text}"',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
                onTap: _editWakeWord,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        const SettingsSection('Đọc chỉ đường'),
        SettingsCard(
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up, color: kAppBlue, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Âm lượng giọng nói',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${(_voiceVolume * 100).round()}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
              Slider(
                value: _voiceVolume,
                onChanged: _setVoiceVolume,
                activeColor: kAppBlue,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                label: '${(_voiceVolume * 100).round()}%',
              ),
              Row(
                children: [
                  const Icon(Icons.speed, color: kAppBlue, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Tốc độ đọc',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${(_ttsSpeechRate * 100).round()}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
              Slider(
                value: _ttsSpeechRate,
                onChanged: _setSpeechRate,
                activeColor: kAppBlue,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                label: '${(_ttsSpeechRate * 100).round()}%',
              ),
              Row(
                children: [
                  const Icon(Icons.music_note, color: kAppBlue, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Giọng cao / thấp',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${_ttsPitch.toStringAsFixed(1)}x',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
              Slider(
                value: _ttsPitch,
                onChanged: _setPitch,
                activeColor: kAppBlue,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${_ttsPitch.toStringAsFixed(1)}x',
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mic, color: kAppBlue, size: 22),
                title: const Text(
                  'Giọng đọc',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Chọn giọng nói TTS (tiếng Việt). Trống = mặc định.',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: Text(
                  _ttsVoiceName.isEmpty ? 'Mặc định' : _ttsVoiceName,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onTap: _pickVoice,
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.graphic_eq, color: kAppBlue, size: 22),
                title: const Text(
                  'Giọng đọc sẵn',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Gói giọng đọc sẵn cho cảnh báo tốc độ. Hệ thống = TTS.',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: Text(
                  kVoicePacks
                      .firstWhere((p) => p.id == _voicePack, orElse: () => kVoicePacks.first)
                      .label
                      .split(' — ')
                      .first,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onTap: _pickVoicePack,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
