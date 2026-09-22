/// GraphHopper / VietMap instruction `sign` → maneuver mapping.
///
/// The sign numbers are GraphHopper's own constants
/// (`com.graphhopper.util.Instruction`), and the two routers used to carry their
/// own copy of this table — one of which mapped **7** (KEEP_RIGHT) to a
/// roundabout, so a keep-right fork on the offline graph announced "đi theo vòng
/// xuyến" at a place with no roundabout. These tests pin the table, and pin the
/// "nothing but a real roundabout may look like a roundabout" invariant.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/core/nav_protocol.dart';

/// GraphHopper's constants, spelled out (not via the function under test).
const _uTurnUnknown = -98;
const _uTurnLeft = -8;
const _keepLeft = -7;
const _roundaboutExit = -6;
const _sharpLeft = -3;
const _left = -2;
const _slightLeft = -1;
const _continue = 0;
const _slightRight = 1;
const _right = 2;
const _sharpRight = 3;
const _finish = 4;
const _reachedVia = 5;
const _roundaboutUse = 6;
const _keepRight = 7;
const _uTurnRight = 8;
const _ferry = 9;

/// (type, modifier) → the icon and the spoken Vietnamese verb.
(int, String) _spoken(int sign) {
  final (type, modifier) = osrmManeuverForInstructionSign(sign);
  final icon = iconForManeuver(type, modifier);
  return (icon, maneuverVerb(icon));
}

void main() {
  group('lateral signs turn the right way', () {
    test('left family', () {
      expect(_spoken(_sharpLeft), (iconTurnLeft, 'rẽ trái'));
      expect(_spoken(_left), (iconTurnLeft, 'rẽ trái'));
      expect(_spoken(_slightLeft), (iconSlightLeft, 'rẽ trái nhẹ'));
    });

    test('right family', () {
      expect(_spoken(_sharpRight), (iconTurnRight, 'rẽ phải'));
      expect(_spoken(_right), (iconTurnRight, 'rẽ phải'));
      expect(_spoken(_slightRight), (iconSlightRight, 'rẽ phải nhẹ'));
    });

    test('straight', () {
      expect(_spoken(_continue), (iconStraight, 'đi thẳng'));
    });
  });

  group('roundabout', () {
    test('6 (USE) and -6 (EXIT) are roundabouts', () {
      expect(osrmManeuverForInstructionSign(_roundaboutUse).$1, 'roundabout');
      expect(_spoken(_roundaboutUse), (iconRoundabout, 'đi theo vòng xuyến'));
      expect(osrmManeuverForInstructionSign(_roundaboutExit).$1, 'roundabout');
    });

    test('⭐ 7 is KEEP RIGHT, not a roundabout (the regression)', () {
      final (type, _) = osrmManeuverForInstructionSign(_keepRight);
      expect(type, isNot('roundabout'));
      expect(_spoken(_keepRight), (iconSlightRight, 'rẽ phải nhẹ'));
    });

    test('-7 is KEEP LEFT, not "continue straight"', () {
      expect(_spoken(_keepLeft), (iconSlightLeft, 'rẽ trái nhẹ'));
    });

    test('no other sign can ever look like a roundabout', () {
      // The invariant that stops this class of bug coming back: scan the whole
      // plausible sign range, not just the codes we happen to think of.
      final roundabouts = <int>[];
      for (var sign = -99; sign <= 99; sign++) {
        final (type, modifier) = osrmManeuverForInstructionSign(sign);
        if (iconForManeuver(type, modifier) == iconRoundabout) {
          roundabouts.add(sign);
        }
      }
      expect(roundabouts, unorderedEquals([_roundaboutUse, _roundaboutExit]));
    });
  });

  group('u-turns, stops and ferries', () {
    test('all three u-turn codes say "quay đầu"', () {
      for (final sign in [_uTurnUnknown, _uTurnLeft, _uTurnRight]) {
        final (icon, verb) = _spoken(sign);
        expect(
          icon,
          anyOf(iconUturnLeft, iconUturnRight),
          reason: 'sign $sign',
        );
        expect(verb, 'quay đầu', reason: 'sign $sign');
      }
    });

    test('4 (FINISH) and 5 (REACHED_VIA) arrive', () {
      expect(_spoken(_finish), (iconArrive, 'đến nơi'));
      expect(_spoken(_reachedVia), (iconArrive, 'đến nơi'));
    });

    test('9 is a ferry leg, not an arrival', () {
      expect(osrmManeuverForInstructionSign(_ferry).$1, 'ferry');
      expect(_spoken(_ferry).$1, isNot(iconArrive));
    });

    test('unknown codes degrade to "đi thẳng" rather than crashing', () {
      for (final sign in <int>[-99, -5, -4, 10, 42, 1000]) {
        final (icon, verb) = _spoken(sign);
        expect(icon, iconStraight, reason: 'sign $sign');
        expect(verb, 'đi thẳng', reason: 'sign $sign');
      }
    });
  });
}
