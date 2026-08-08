/// Binary compact protocol for the **ESP32 2.8" navigation display**
/// (ESP32_OSM_NAV `ble_nav.cpp` — the NAV-OSM board).
///
/// Unlike the DA14585 E-ink clock's framed binary messages, this board is a
/// pure receiver that renders a base map itself from local offline tiles and
/// only needs a small overlay from the phone: route polyline, live position,
/// next maneuver, ETA and the current time.
///
/// Frame format (`ble_nav.cpp`, mirrored by `web_ble_nav/index.html`):
///   [0xAA][0x55][type][len_lo][len_hi][payload...]    (len little-endian)
///     type 0x01 ROUTE: zoom(u8) count(u16) lat0/lon0(i32 x1e7)
///                      then (count-1) x [dlat(i16 x1e5) dlon(i16 x1e5)]
///     type 0x02 POS  : lat(i32 x1e7) lon(i32 x1e7) spd(u8) hdg(u16) sl(u8)
///     type 0x03 NAV  : dist(u16) modId(u8) slen(u8) street[slen]  (UTF-8)
///     type 0x04 ETA  : h(u8) m(u8) alen(u8) arrive[alen]          (UTF-8)
///     type 0x05 CLOCK: h(u8) m(u8)
///
/// The firmware finalizes packets on the length framing alone, so no
/// terminator byte is needed (binary frames may span chunked BLE writes).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import 'package:navbridge/core/nav_protocol.dart';

// ---- framing ----
const int mapFrameMagic0 = 0xAA;
const int mapFrameMagic1 = 0x55;

// ---- packet types ----
const int mapTypeRoute = 0x01;
const int mapTypePos = 0x02;
const int mapTypeNav = 0x03;
const int mapTypeEta = 0x04;
const int mapTypeClock = 0x05;

// ---- maneuver ids (match `navManeuverName` in ble_nav.cpp) ----
const int mapManeuverStraight = 0;
const int mapManeuverLeft = 1;
const int mapManeuverRight = 2;
const int mapManeuverSlightLeft = 3;
const int mapManeuverSlightRight = 4;
const int mapManeuverUturn = 5;
const int mapManeuverRoundabout = 6;
const int mapManeuverArrive = 7;

/// Firmware street/arrive buffer size — `NAV_MAX_STREET = 64` bytes. The
/// parser reserves one byte for the terminator, so payload text is capped at
/// [mapMaxStreetBytes] - 1.
const int mapMaxStreetBytes = 64;

/// Maximum number of route points the board will draw (`NAV_MAX_ROUTE_POINTS`).
const int mapMaxRoutePoints = 512;

/// Map an E-ink clock icon code (from [iconForManeuver]) to the board's
/// maneuver id. Same maneuver vocabulary as the OSRM/Vietmap types.
int mapManeuverIdForIcon(int iconCode) => switch (iconCode) {
  iconTurnLeft => mapManeuverLeft,
  iconTurnRight => mapManeuverRight,
  iconSlightLeft => mapManeuverSlightLeft,
  iconSlightRight => mapManeuverSlightRight,
  iconUturnLeft || iconUturnRight => mapManeuverUturn,
  iconRoundabout => mapManeuverRoundabout,
  iconArrive => mapManeuverArrive,
  _ => mapManeuverStraight, // unknown / straight
};

/// Wrap a payload in the `0xAA 0x55` frame header with its length.
Uint8List _frame(int type, Uint8List payload) {
  final f = Uint8List(5 + payload.length);
  f[0] = mapFrameMagic0;
  f[1] = mapFrameMagic1;
  f[2] = type & 0xFF;
  f[3] = payload.length & 0xFF; // lenL
  f[4] = (payload.length >> 8) & 0xFF; // lenH
  f.setRange(5, f.length, payload);
  return f;
}

/// UTF-8 bytes of [s], truncated to the firmware's street buffer (leaving
/// room for the terminator it appends).
Uint8List _utf8Capped(String s) {
  final b = Uint8List.fromList(utf8.encode(s));
  final max = mapMaxStreetBytes - 1;
  return b.length <= max ? b : Uint8List.sublistView(b, 0, max);
}

/// `<route>` — the full route polyline (sent once per route / on re-route).
///
/// Decimates to at most [mapMaxRoutePoints] points. The first point is an
/// absolute lat/lon (×1e7); the rest are deltas (×1e5) relative to the
/// previous point, clamped to i16 so the firmware's cumulative decode stays
/// valid.
Uint8List buildMapRouteFrame(List<LatLng> points, {int zoom = 15}) {
  // The board ignores routes with < 2 points; pad a single point (or an
  // empty list) into a valid degenerate 2-point polyline.
  final pts = points.length >= 2
      ? points
      : points.isEmpty
      ? const [LatLng(0, 0), LatLng(0, 0)]
      : [points.first, points.first];
  final n = pts.length.clamp(2, mapMaxRoutePoints);
  // 3 (zoom+count) + 8 (first abs lat/lon) + (n-1)*4 (deltas).
  final payload = Uint8List(3 + 8 + (n - 1) * 4);
  payload[0] = zoom & 0xFF;
  payload[1] = n & 0xFF;
  payload[2] = (n >> 8) & 0xFF;

  var lat = (pts[0].latitude * 1e7).round();
  var lon = (pts[0].longitude * 1e7).round();
  _writeInt32(payload, 3, lat);
  _writeInt32(payload, 7, lon);

  for (var i = 1; i < n; i++) {
    final la = (pts[i].latitude * 1e7).round();
    final lo = (pts[i].longitude * 1e7).round();
    final off = 11 + (i - 1) * 4;
    // Delta in 1e5 units — rounded (not floored) so the firmware's
    // `lat += dl * 100` reconstruction stays accurate to 0.00001°.
    _writeInt16(payload, off, _clampI16(((la - lat) / 100).round()));
    _writeInt16(payload, off + 2, _clampI16(((lo - lon) / 100).round()));
    lat = la;
    lon = lo;
  }
  return _frame(mapTypeRoute, payload);
}

/// `<pos>` — live position (~1 Hz) driving the car marker + auto-follow.
Uint8List buildMapPosFrame({
  required double lat,
  required double lon,
  int spd = 0,
  int hdg = 0,
  int speedLimit = 0,
}) {
  final p = Uint8List(12);
  _writeInt32(p, 0, (lat * 1e7).round());
  _writeInt32(p, 4, (lon * 1e7).round());
  p[8] = spd.clamp(0, 255); // km/h
  _writeUint16(p, 9, hdg % 360); // deg, 0=N
  p[11] = speedLimit.clamp(0, 255); // km/h, 0 = unknown
  return _frame(mapTypePos, p);
}

/// `<nav>` — next-maneuver HUD (turn arrow + distance + street).
Uint8List buildMapNavFrame({
  required int dist,
  required int maneuverId,
  required String street,
}) {
  final s = _utf8Capped(street);
  final p = Uint8List(4 + s.length);
  _writeUint16(p, 0, dist.clamp(0, 0xFFFF)); // meters
  p[2] = maneuverId & 0xFF;
  p[3] = s.length;
  p.setRange(4, p.length, s);
  return _frame(mapTypeNav, p);
}

/// `<eta>` — ETA + arrive-address banner (optional).
Uint8List buildMapEtaFrame({
  required int hour,
  required int minute,
  String arrive = '',
}) {
  final a = _utf8Capped(arrive);
  final p = Uint8List(3 + a.length);
  p[0] = hour.clamp(0, 23);
  p[1] = minute.clamp(0, 59);
  p[2] = a.length;
  p.setRange(3, p.length, a);
  return _frame(mapTypeEta, p);
}

/// `<clock>` — current time for the HUD (send when the minute ticks).
Uint8List buildMapClockFrame({required int hour, required int minute}) {
  final p = Uint8List(2);
  p[0] = hour.clamp(0, 23);
  p[1] = minute.clamp(0, 59);
  return _frame(mapTypeClock, p);
}

// ---- little-endian helpers ----

int _clampI16(int v) => v.clamp(-32768, 32767).toInt();

void _writeInt32(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
  b[off + 2] = (v >> 16) & 0xFF;
  b[off + 3] = (v >> 24) & 0xFF;
}

void _writeUint16(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
}

void _writeInt16(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
}
