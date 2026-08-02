import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/nav_protocol.dart';

void main() {
  test('nav frame layout matches firmware/PROTOCOL.md', () {
    final f = buildNavFrame(
      meter: 141,
      iconCode: iconTurnLeft,
      hour: 7,
      minute: 17,
      text: 'Vườn Lài',
    );
    expect(f[0], 0x20);
    expect(f[1], 0x07);
    expect(f[2], 0x0A);
    expect(f[3], 141 & 0xFF);
    expect(f[4], (141 >> 8) & 0xFF);
    expect(f[5], iconTurnLeft);
    expect(f[6], 7);
    expect(f[7], 17);
    expect(f[8], utf8.encode('Vườn Lài').length);
    expect(f.last, 0xAF);
  });

  test('OSRM maneuver -> clock icon', () {
    expect(iconForManeuver('turn', 'left'), iconTurnLeft);
    expect(iconForManeuver('turn', 'right'), iconTurnRight);
    expect(iconForManeuver('turn', 'slight left'), iconSlightLeft);
    expect(iconForManeuver('arrive', null), iconArrive);
    expect(iconForManeuver('roundabout', 'left'), iconRoundabout);
    expect(iconForManeuver('continue', 'straight'), iconStraight);
  });
}
