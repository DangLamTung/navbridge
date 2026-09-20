/// Tests for [SoundAlerts] and asset audio integration.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/settings.dart' show voicePack;
import 'package:navbridge/services/sound_alerts.dart';
import 'package:navbridge/services/voice_guide.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final playedAssets = <String>[];
  final spoken = <String>[];

  setUp(() {
    playedAssets.clear();
    spoken.clear();
    voicePack = 'voice_vn_fast'; // the shipped default
    // The queue only runs once the engine reports ready; unit tests have no
    // platform TTS engine, so mark it ready explicitly.
    VoiceGuide.instance.debugSetReady(true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('navbridge/audio'), (
          MethodCall call,
        ) async {
          if (call.method == 'playAsset') {
            final asset = call.arguments['asset'] as String?;
            if (asset != null) {
              playedAssets.add(asset);
              return true;
            }
          }
          return null;
        });
    // flutter_tts: record what was spoken so ordering can be asserted.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          MethodCall call,
        ) async {
          if (call.method == 'speak') {
            final t = call.arguments is Map
                ? (call.arguments['text'] as String?)
                : call.arguments as String?;
            if (t != null) spoken.add(t);
          }
          return 1;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('navbridge/audio'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    VoiceGuide.instance.debugSetReady(false);
    VoiceGuide.instance.stop();
  });

  /// Let the announcement queue run to completion.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('SoundAlerts', () {
    test('supportedLimits contains standard Vietnam speeds', () {
      expect(SoundAlerts.supportedLimits.contains(50), isTrue);
      expect(SoundAlerts.supportedLimits.contains(60), isTrue);
      expect(SoundAlerts.supportedLimits.contains(80), isTrue);
      expect(SoundAlerts.supportedLimits.contains(120), isTrue);
      expect(SoundAlerts.supportedLimits.contains(55), isFalse);
    });

    test('playBeepBeep invokes correct asset', () async {
      final ok = await SoundAlerts.instance.playBeepBeep();
      expect(ok, isTrue);
      expect(playedAssets, contains('assets/audio/common/beepbeep.mp3'));
    });

    test('playSpeedAlarm invokes correct asset', () async {
      final ok = await SoundAlerts.instance.playSpeedAlarm();
      expect(ok, isTrue);
      expect(playedAssets, contains('assets/audio/common/speed_limit.mp3'));
    });

    test('playArrival invokes correct asset', () async {
      final ok = await SoundAlerts.instance.playArrival();
      expect(ok, isTrue);
      expect(playedAssets, contains('assets/audio/common/waze_to_goal.mp3'));
    });

    test('playMicStart and playMicEnd invoke correct assets', () async {
      await SoundAlerts.instance.playMicStart();
      await SoundAlerts.instance.playMicEnd();
      expect(playedAssets, [
        'assets/audio/common/rec_start.mp3',
        'assets/audio/common/rec_end.mp3',
      ]);
    });

    test('playCurrentSpeedLimit plays the default (fast) pack clip', () async {
      final ok = await SoundAlerts.instance.playCurrentSpeedLimit(60);
      expect(ok, isTrue);
      await settle();
      expect(
        playedAssets,
        contains('assets/audio/voice_vn_fast/current_speed_60.mp3'),
      );
    });

    test('playCurrentSpeedLimit returns false for unsupported limit', () async {
      final ok = await SoundAlerts.instance.playCurrentSpeedLimit(55);
      expect(ok, isFalse);
      await settle();
      expect(playedAssets, isEmpty);
    });

    test('playNextSpeedLimit plays clip for supported limit', () async {
      final ok = await SoundAlerts.instance.playNextSpeedLimit(80);
      expect(ok, isTrue);
      await settle();
      expect(
        playedAssets,
        contains('assets/audio/voice_vn_fast/next_speed_80.mp3'),
      );
    });

    test('playOverSpeed plays overspeed clip', () async {
      final ok = await SoundAlerts.instance.playOverSpeed();
      expect(ok, isTrue);
      await settle();
      expect(
        playedAssets,
        contains('assets/audio/voice_vn_fast/over_speed_limit.mp3'),
      );
    });

    test('the old Thai Ngoc Bich pack still resolves when selected', () async {
      voicePack = 'voice_thai_ngoc_bich';
      await SoundAlerts.instance.playCurrentSpeedLimit(50);
      await settle();
      expect(
        playedAssets,
        contains('assets/audio/voice_thai_ngoc_bich/current_speed_50.mp3'),
      );
    });

    test('an empty pack id falls back to TTS (no clip played)', () async {
      voicePack = '';
      final ok = await SoundAlerts.instance.playCurrentSpeedLimit(50);
      expect(ok, isFalse);
      await settle();
      expect(playedAssets, isEmpty);
    });

    group('announcement queue never truncates', () {
      test('queued sentences all play, in order, none dropped', () async {
        final v = VoiceGuide.instance;
        v.speak('câu một');
        v.speak('câu hai');
        v.speak('câu ba');
        await settle();
        await settle();
        await settle();
        await settle();
        expect(spoken, ['câu một', 'câu hai', 'câu ba']);
      });

      test('an identical repeat is not queued twice', () async {
        final v = VoiceGuide.instance;
        v.speak('Biển STOP sắp tới');
        v.speak('Biển STOP sắp tới');
        await settle();
        await settle();
        await settle();
        expect(spoken, ['Biển STOP sắp tới']);
      });

      test('a clip and a sentence share one queue (no overlap)', () async {
        final v = VoiceGuide.instance;
        v.speak('Rẽ trái sau 300 mét');
        await SoundAlerts.instance.playOverSpeed();
        await settle();
        await settle();
        await settle();
        // The sentence went first and the clip followed — never together.
        expect(spoken, ['Rẽ trái sau 300 mét']);
        expect(playedAssets, [
          'assets/audio/voice_vn_fast/over_speed_limit.mp3',
        ]);
      });
    });
  });
}
