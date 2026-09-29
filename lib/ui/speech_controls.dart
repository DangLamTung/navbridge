import 'package:flutter/material.dart';

import 'package:navbridge/core/settings.dart'
    show ttsSpeechRate, voiceBoostMax;
import 'package:navbridge/pages/settings/settings_save.dart'
    show saveAllSettings;
import 'package:navbridge/services/offline_tiles.dart' show voiceVolume;
import 'package:navbridge/services/voice_guide.dart'
    show VoiceGuide, effectiveSpeechRate;

/// Speaker speed + volume, in one control.
///
/// One widget for every surface that needs it — the debug sim panel and the
/// app's voice settings — so the two can never drift apart. Both sliders write
/// the SAME globals the settings page uses ([ttsSpeechRate], [voiceVolume]) and
/// push them to the engine immediately, because a driver tuning the voice
/// mid-route expects to hear the change on the next sentence, not after a
/// restart.
///
/// The speed slider is a slow→fast preference, NOT a fraction of normal. On web
/// the value is assigned straight to `SpeechSynthesisUtterance.rate`, where 1.0
/// is the browser's normal speed, so the raw preference is shown alongside the
/// rate actually used ([effectiveSpeechRate]) — 55% on the slider means about
/// half speed if read as a fraction, which is exactly the confusion that made
/// the web build sound "too slow".
class SpeechControls extends StatefulWidget {
  const SpeechControls({super.key, this.dense = false});

  /// Tighter layout for the sim panel, which is a narrow console column.
  final bool dense;

  @override
  State<SpeechControls> createState() => _SpeechControlsState();
}

class _SpeechControlsState extends State<SpeechControls> {
  late double _rate = ttsSpeechRate;
  late double _volume = voiceVolume;

  Future<void> _apply() async {
    // The volume slider owns the boost cap too: a media-stream boost above the
    // chosen level would defeat the setting (see _setVoiceVolume in
    // voice_settings_page.dart, which does the same thing).
    voiceBoostMax = _volume;
    await saveAllSettings();
    await VoiceGuide.instance.applySpeech();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.dense ? 12.0 : 13.0;
    final pct = (_rate * 100).round();
    final effective = effectiveSpeechRate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.record_voice_over, color: kSpeechBlue, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Giọng nói',
                style: TextStyle(fontSize: title, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${effective.toStringAsFixed(2)}x',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 4),
            Icon(Icons.speed, size: 18, color: Colors.grey[600]),
            Expanded(
              child: Slider(
                value: _rate,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                activeColor: kSpeechBlue,
                label: 'Tốc độ $pct%',
                onChanged: (v) {
                  setState(() {
                    _rate = v;
                    ttsSpeechRate = v;
                  });
                  _apply();
                },
              ),
            ),
            SizedBox(
              width: 46,
              child: Text('$pct%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 4),
            Icon(Icons.volume_up, size: 18, color: Colors.grey[600]),
            Expanded(
              child: Slider(
                value: _volume,
                min: 0.0,
                max: 1.0,
                divisions: 10,
                activeColor: kSpeechBlue,
                label: 'Âm lượng ${(_volume * 100).round()}%',
                onChanged: (v) {
                  setState(() {
                    _volume = v;
                    voiceVolume = v;
                  });
                  _apply();
                },
              ),
            ),
            SizedBox(
              width: 46,
              child: Text('${(_volume * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            ),
          ],
        ),
      ],
    );
  }
}

/// The one colour this control uses. Kept local so the widget drops into both a
/// debug console and a settings page without importing either theme.
const Color kSpeechBlue = Color(0xFF1E6FD9);
