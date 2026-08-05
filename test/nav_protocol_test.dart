/// Tests for the E-ink clock navigation frame protocol (`nav_protocol.dart`).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/nav_protocol.dart';

void main() {
  group('buildNavFrame', () {
    test('layout matches firmware/PROTOCOL.md §7', () {
      final f = buildNavFrame(
        meter: 141,
        iconCode: iconTurnLeft,
        hour: 7,
        minute: 17,
        text: 'Vườn Lài',
      );
      expect(f[0], 0x20); // magic
      expect(f[1], 0x07); // magic
      expect(f[2], 0x0A); // navigation message
      expect(f[3], 141 & 0xFF); // meterL
      expect(f[4], (141 >> 8) & 0xFF); // meterH
      expect(f[5], iconTurnLeft);
      expect(f[6], 7); // hour
      expect(f[7], 17); // minute
      expect(f[8], utf8.encode('Vườn Lài').length); // lenTxt
      expect(f.last, 0xAF); // end frame
    });

    test('encodes the UTF-8 payload bytes after the header', () {
      const text = 'Đi thẳng vào đường Nguyễn Huệ';
      final tb = utf8.encode(text);
      final f = buildNavFrame(
        meter: 10,
        iconCode: iconStraight,
        hour: 0,
        minute: 0,
        text: text,
      );
      expect(f[8], tb.length);
      expect(f.length, 9 + tb.length + 1);
      for (var i = 0; i < tb.length; i++) {
        expect(f[9 + i], tb[i]);
      }
    });

    test('clamps the meter to 16 bits', () {
      final f = buildNavFrame(
        meter: 0x1FFFF,
        iconCode: iconStraight,
        hour: 0,
        minute: 0,
        text: '',
      );
      expect(f[3], 0xFF);
      expect(f[4], 0xFF);
      expect(f[8], 0);
      expect(f.length, 10); // 9 header + 0 text + 1 end
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

  test('etaFromRemaining stays within a day', () {
    final (h, m) = etaFromRemaining(15 * 60);
    expect(h, inInclusiveRange(0, 23));
    expect(m, inInclusiveRange(0, 59));
  });
}
