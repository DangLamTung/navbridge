/// Tests for navigation protocol & maneuvers (`nav_protocol.dart`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/nav_protocol.dart';

void main() {
  group('iconSymbol', () {
    test('arrow symbols point in driving direction', () {
      expect(iconSymbol(iconTurnLeft), '←');
      expect(iconSymbol(iconTurnRight), '→');
      expect(iconSymbol(iconSlightLeft), '↖');
      expect(iconSymbol(iconSlightRight), '↗');
      expect(iconSymbol(iconStraight), '↑');
      expect(iconSymbol(iconUturnLeft), '↩');
      expect(iconSymbol(iconUturnRight), '↩');
      expect(iconSymbol(iconRoundabout), '↻');
      expect(iconSymbol(iconArrive), '⛳');
      expect(iconSymbol(iconUnknown), '↑');
    });
  });

  group('iconForManeuver', () {
    test('maps OSRM/Vietmap maneuvers to clock icons', () {
      expect(iconForManeuver('turn', 'left'), iconTurnLeft);
      expect(iconForManeuver('turn', 'right'), iconTurnRight);
      expect(iconForManeuver('turn', 'slight left'), iconSlightLeft);
      expect(iconForManeuver('turn', 'slight right'), iconSlightRight);
      expect(iconForManeuver('turn', 'sharp left'), iconTurnLeft);
      expect(iconForManeuver('turn', 'sharp right'), iconTurnRight);
      expect(iconForManeuver('uturn', 'left'), iconUturnLeft);
      expect(iconForManeuver('uturn', 'right'), iconUturnRight);
      expect(iconForManeuver('roundabout', 'left'), iconRoundabout);
      expect(iconForManeuver('exit roundabout', 'straight'), iconRoundabout);
      expect(iconForManeuver('rotary', null), iconRoundabout);
      expect(iconForManeuver('arrive', 'straight'), iconArrive);
      expect(iconForManeuver('depart', null), iconStraight);
      expect(iconForManeuver('continue', 'straight'), iconStraight);
      expect(iconForManeuver('new name', null), iconStraight);
      expect(iconForManeuver(null, null), iconStraight);
    });
  });

  group('formatDistance', () {
    test('meters below 1 km', () {
      expect(formatDistance(450), '450 m');
      expect(formatDistance(999), '999 m');
      expect(formatDistance(0), '0 m');
    });

    test('kilometres use Vietnamese decimal style', () {
      expect(formatDistance(1000), '1,0 km');
      expect(formatDistance(1200), '1,2 km');
      expect(formatDistance(12345), '12,3 km');
    });
  });

  group('formatDistanceSpoken', () {
    test('says mét under 1 km', () {
      expect(formatDistanceSpoken(450), '450 mét');
      expect(formatDistanceSpoken(999), '999 mét');
      expect(formatDistanceSpoken(0), '0 mét');
    });

    test('says km from 1 km up', () {
      expect(formatDistanceSpoken(1000), '1,0 km');
      expect(formatDistanceSpoken(1200), '1,2 km');
      expect(formatDistanceSpoken(12345), '12,3 km');
    });
  });

  group('maneuverVerb', () {
    test('Vietnamese verbs for spoken guidance', () {
      expect(maneuverVerb(iconTurnLeft), 'rẽ trái');
      expect(maneuverVerb(iconTurnRight), 'rẽ phải');
      expect(maneuverVerb(iconSlightLeft), 'rẽ trái nhẹ');
      expect(maneuverVerb(iconSlightRight), 'rẽ phải nhẹ');
      expect(maneuverVerb(iconUturnLeft), 'quay đầu');
      expect(maneuverVerb(iconUturnRight), 'quay đầu');
      expect(maneuverVerb(iconRoundabout), 'đi theo vòng xuyến');
      expect(maneuverVerb(iconArrive), 'đến nơi');
      expect(maneuverVerb(iconStraight), 'đi thẳng');
      expect(maneuverVerb(iconUnknown), 'đi thẳng');
    });
  });

  test('etaFromRemaining stays within a day and handles edge cases', () {
    final (h, m) = etaFromRemaining(15 * 60);
    expect(h, inInclusiveRange(0, 23));
    expect(m, inInclusiveRange(0, 59));

    final (hZero, mZero) = etaFromRemaining(0);
    expect(hZero, inInclusiveRange(0, 23));
    expect(mZero, inInclusiveRange(0, 59));

    final (hNeg, mNeg) = etaFromRemaining(-100);
    expect(hNeg, inInclusiveRange(0, 23));
    expect(mNeg, inInclusiveRange(0, 59));
  });
}
