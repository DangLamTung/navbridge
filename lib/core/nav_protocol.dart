/// Port of `scripts/nav_protocol.py` — the E-ink clock navigation frame.
///
/// Frame format (firmware/PROTOCOL.md §7):
///   [0x20][0x07][0x0A][meterL][meterH][icon][hour][minute][lenTxt][text...][0xAF]
///
/// Icon codes are the authoritative ones from the official app
/// (com.ledeink.app MapNotificationService.parseIconCode()):
///   1=straight, 2=turn-left, 3=turn-right, 4=slight-left, 5=slight-right,
///   6=uturn-left, 7=uturn-right, 8=roundabout, 9=arrive, 0=unknown
library;

import 'dart:convert';
import 'dart:typed_data';

const int iconUnknown = 0;
const int iconStraight = 1;
const int iconTurnLeft = 2;
const int iconTurnRight = 3;
const int iconSlightLeft = 4;
const int iconSlightRight = 5;
const int iconUturnLeft = 6;
const int iconUturnRight = 7;
const int iconRoundabout = 8;
const int iconArrive = 9;

const Map<int, String> iconNames = {
  iconUnknown: 'unknown',
  iconStraight: 'straight',
  iconTurnLeft: 'turn-left',
  iconTurnRight: 'turn-right',
  iconSlightLeft: 'slight-left',
  iconSlightRight: 'slight-right',
  iconUturnLeft: 'uturn-left',
  iconUturnRight: 'uturn-right',
  iconRoundabout: 'roundabout',
  iconArrive: 'arrive',
};

/// A compact arrow symbol for an [iconCode] — used by notifications and the
/// ESP banner text (ASCII-safe). '→' left, '←' right, '↑' straight, '↩' u-turn.
String iconSymbol(int iconCode) => switch (iconCode) {
  iconTurnLeft => '←',
  iconTurnRight => '→',
  iconSlightLeft => '↙',
  iconSlightRight => '↘',
  iconUturnLeft || iconUturnRight => '↩',
  iconRoundabout => '↻',
  iconArrive => '⛳',
  _ => '↑', // straight / unknown
};

/// Build the navigation frame bytes to send over BLE.
Uint8List buildNavFrame({
  required int meter,
  required int iconCode,
  required int hour,
  required int minute,
  required String text,
}) {
  final m = meter.clamp(0, 0xFFFF);
  final tb = Uint8List.fromList(utf8.encode(text));
  final frame = Uint8List(9 + tb.length + 1);
  frame[0] = 0x20; // magic
  frame[1] = 0x07; // magic
  frame[2] = 0x0A; // navigation message (0x0B = time sync)
  frame[3] = m & 0xFF; // meterL
  frame[4] = (m >> 8) & 0xFF; // meterH
  frame[5] = iconCode & 0xFF;
  frame[6] = hour & 0xFF;
  frame[7] = minute & 0xFF;
  frame[8] = tb.length & 0xFF; // lenTxt
  frame.setRange(9, 9 + tb.length, tb);
  frame[frame.length - 1] = 0xAF; // end frame
  return frame;
}

/// Map a Vietmap navigation maneuver (modifierType + modifier) to the clock
/// icon code. Same vocabulary as OSRM/Mapbox: type=turn, modifier=left, ...
int iconForManeuver(String? type, String? modifier) {
  final t = (type ?? '').toLowerCase().replaceAll(' ', '');
  final m = (modifier ?? '').toLowerCase().replaceAll(' ', '');

  if (t == 'arrive') return iconArrive;
  if (t == 'roundabout' ||
      t == 'rotary' ||
      t == 'roundaboutturn' ||
      t == 'exitroundabout' ||
      t == 'exitrotary') {
    return iconRoundabout;
  }
  if (t == 'uturn' || m == 'uturn') {
    return (m == 'left' || m == 'uturn') ? iconUturnLeft : iconUturnRight;
  }
  if (m == 'left' || m == 'sharpleft') return iconTurnLeft;
  if (m == 'right' || m == 'sharpright') return iconTurnRight;
  if (m == 'slightleft') return iconSlightLeft;
  if (m == 'slightright') return iconSlightRight;
  return iconStraight; // depart / continue / new name / merge / ...
}

/// ETA as (hour, minute) from the remaining seconds until arrival.
(int, int) etaFromRemaining(double remainingSeconds) {
  final now = DateTime.now();
  final totalMin =
      (now.hour * 60 + now.minute + (remainingSeconds / 60).round()) % 1440;
  return ((totalMin ~/ 60) % 24, totalMin % 60);
}

/// '450 m' / '1,2 km' — Vietnamese style, like the official app.
String formatDistance(num meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  return '${meters.round()} m';
}

/// Spoken Vietnamese distance — "450 mét" / "1,2 km" — so TTS says a natural
/// unit: meters under 1 km, kilometres above (the UI card already uses
/// [formatDistance], the voice now matches it).
String formatDistanceSpoken(num meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  return '${meters.round()} mét';
}

/// Vietnamese guidance verb for a clock icon code ("rẽ trái", "đi thẳng", …).
/// Shared by the spoken announcements and the on-screen Vietmap-style banner.
String maneuverVerb(int code) => switch (code) {
  iconTurnLeft => 'rẽ trái',
  iconTurnRight => 'rẽ phải',
  iconSlightLeft => 'rẽ trái nhẹ',
  iconSlightRight => 'rẽ phải nhẹ',
  iconUturnLeft || iconUturnRight => 'quay đầu',
  iconRoundabout => 'đi theo vòng xuyến',
  iconArrive => 'đến nơi',
  _ => 'đi thẳng',
};
