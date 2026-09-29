/// What the driver HEARS — sign callouts, khu dân cư boundaries, audio queue
///
/// Phase-1 consolidation (2026-09-28): these were 3 separate
/// files, one per bugfix, each re-loading the same bundled pack in its own
/// test isolate. The assertions are unchanged — each former file is one
/// group below, so its file-local helpers keep their own scope.
///
///   ///   sign_callout_phrase_test.dart
///   sign_zone_phrase_test.dart
///   sound_alerts_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:navbridge/core/settings.dart' show voicePack;
import 'package:navbridge/pages/navigation/navigation_page.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/sound_alerts.dart';
import 'package:navbridge/services/voice_guide.dart';
import 'package:navbridge/ui/sign_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sign_callout_phrase', () {
      group('sign callout phrases', () {

        test('5 cases', () {
        // ---- case: entering a built-up area says exactly Bắt đầu khu dân cư ----
        (() {
            expect(
              signCalloutPhrase(RoadSignKind.populated, 300, near: false),
              'Bắt đầu khu dân cư phía trước',
            );
            expect(
              signCalloutPhrase(RoadSignKind.populated, 90, near: true),
              'Bắt đầu khu dân cư',
            );

        })();


        // ---- case: leaving a built-up area says exactly Hết khu dân cư ----
        (() {
            expect(
              signCalloutPhrase(RoadSignKind.populatedEnd, 300, near: false),
              'Hết khu dân cư phía trước',
            );
            expect(
              signCalloutPhrase(RoadSignKind.populatedEnd, 90, near: true),
              'Hết khu dân cư',
            );

        })();


        // ---- case: a boundary never claims a distance ----
        (() {
            // Its point may be a zone-dump vertex, not the post on the carriageway.
            for (final k in [RoadSignKind.populated, RoadSignKind.populatedEnd]) {
              for (final m in [80.0, 250.0, 900.0]) {
                for (final near in [true, false]) {
                  expect(signCalloutPhrase(k, m, near: near), isNot(contains('mét')),
                      reason: '${k.key} at $m m (near=$near)');
                  expect(signCalloutPhrase(k, m, near: near), isNot(contains('km')),
                      reason: '${k.key} at $m m (near=$near)');
                }
              }
            }

        })();


        // ---- case: the boundary kinds load, and the JSON keys map to them ----
        (() {
            expect(RoadSignKind.fromKey('populated'), RoadSignKind.populated);
            expect(RoadSignKind.fromKey('populated_end'), RoadSignKind.populatedEnd);
            expect(droppedSignKinds, isEmpty,
                reason: 'the app must not drop the boundaries it announces');

        })();


        // ---- case: every kind still has a phrase ----
        (() {
            for (final k in RoadSignKind.values) {
              expect(signCalloutPhrase(k, 200, near: false), isNotEmpty,
                  reason: k.key);
              expect(signCalloutPhrase(k, 90, near: true), isNotEmpty,
                  reason: k.key);
            }

        })();
        });

      });
  });

  group('sign_zone_phrase', () {
      group('zone-referenced signs', () {

        test('4 cases', () {
        // ---- case: the eight E-DOG zone kinds are the ones listed ----
        (() {
            expect(
              zoneSignKinds.map((k) => k.key).toSet(),
              {
                'toll_booth',
                'no_passing',
                'no_passing_end',
                'slow_down',
                'tunnel',
                'railway_crossing',
                // khu đông dân cư boundaries — same E-DOG zone dump, announced
                // without a distance (user, 2026-09-28: "say Bắt đầu khu dân cư /
                // Hết khu dân cư").
                'populated',
                'populated_end',
              },
            );

        })();


        // ---- case: a zone kind gets NO spoken distance, at any range ----
        (() {
            for (final k in zoneSignKinds) {
              expect(signAheadTail(k, 250), '', reason: '${k.key} at 250 m');
              expect(signAheadTail(k, 1200), '', reason: '${k.key} at 1.2 km');
            }

        })();


        // ---- case: every other kind still gets one ----
        (() {
            expect(signAheadTail(RoadSignKind.stop, 250), ' 250 mét');
            expect(signAheadTail(RoadSignKind.signal, 90), ' 90 mét');
            expect(signAheadTail(RoadSignKind.noLeftTurn, 1500), ' 1,5 km');
            final others = RoadSignKind.values.where((k) => !zoneSignKinds.contains(k));
            expect(others.length, RoadSignKind.values.length - zoneSignKinds.length);
            for (final k in others) {
              expect(signAheadTail(k, 300), isNotEmpty, reason: k.key);
            }

        })();


        // ---- case: zone kinds have real artwork — except the ones drawn as panels ----
        (() {
            // The console draws the sign itself, so a zone kind with no bundled art
            // falls back to a letter exactly where the position is least certain.
            //
            // `toll_booth` is that case, and it is NOT an oversight: a verified QCVN
            // "Trạm thu phí" sign does not exist on Commons (searched 2026-09-24 — the
            // hits are PHOTOS of toll plazas: "Trạm thu phí Cao Bồ", "... Sông Phan",
            // "... Quán Hàu"). The tempting lead `Vietnam road sign R412a.svg` is
            // "Lane for coaches" per its own metadata, not "TRẠM". Drawing our own
            // toll sign is the thing the user forbade ("dont draw anyshit"), so the
            // marker stays a letter until real artwork is verified.
            //
            // R.420 / R.421 (bắt đầu / hết khu đông dân cư) are the same story, and
            // these the driver DOES need to see: they get a blue text panel
            // ("KHU DÂN CƯ" / "HẾT KHU DÂN CƯ") — a label, not a redrawn official
            // sign.
            expect(
              zoneSignKinds
                  .where((k) => SignIcon.assetFor(k) == null)
                  .map((k) => k.key)
                  .toList()
                ..sort(),
              ['populated', 'populated_end', 'toll_booth'],
            );
            for (final k in zoneSignKinds.where((k) =>
                k != RoadSignKind.tollBooth &&
                k != RoadSignKind.populated &&
                k != RoadSignKind.populatedEnd)) {
              expect(SignIcon.assetFor(k), isNotNull, reason: k.key);
            }

        })();
        });

      });
  });

  group('sound_alerts', () {
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






        test('playCurrentSpeedLimit returns false for unsupported limit', () async {
          final ok = await SoundAlerts.instance.playCurrentSpeedLimit(55);
          expect(ok, isFalse);
          await settle();
          expect(playedAssets, isEmpty);
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
  });
}
