/// Minimal NMEA parser for the ESP32 GPS bridge (NavBridge).
///
/// The board (ESP32_OSM_NAV `gps_ublox.c`) broadcasts raw NMEA sentences
/// over BLE; `BleMapClock.gpsNmeaStream` delivers them here. This merges the
/// two sentences a u-blox emits at ~1 Hz into a single [NmeaFix]:
///   - `$GPGGA` / `$GNGGA` → position + fix quality + satellites + HDOP
///   - `$GPRMC` / `$GNRMC` → validity (A/V) + speed + course + UTC time
/// GGA and RMC can arrive in any order/interleaved, so the parser keeps the
/// latest of each and produces a merged fix from whatever has been seen.
library;

/// A merged GPS fix from the ESP32 receiver.
class NmeaFix {
  /// True when we have coordinates AND a fix (GGA quality > 0 or RMC status A).
  final bool valid;
  final double lat; // degrees, N positive
  final double lon; // degrees, E positive
  final double speedMps; // ground speed (RMC knots → m/s)
  final double heading; // true course, deg 0..359
  final int quality; // 0 none, 1 GPS, 2 DGPS
  final int sats;
  final double hdop;
  final DateTime? timeUtc;

  const NmeaFix({
    required this.valid,
    required this.lat,
    required this.lon,
    required this.speedMps,
    required this.heading,
    required this.quality,
    required this.sats,
    required this.hdop,
    this.timeUtc,
  });

  /// Rough horizontal accuracy estimate from HDOP (GPS rule of thumb ~6 m per
  /// HDOP unit), clamped to a sane 3–60 m so the outlier gate has a usable
  /// number even when the module omits HDOP.
  double get accuracyMeters {
    if (hdop <= 0) return 12.0;
    return (hdop * 6.0).clamp(3.0, 60.0);
  }
}

/// Stateful GGA+RMC → [NmeaFix] parser. Feed one raw line per call; a line
/// with position data returns the merged fix, otherwise null.
class NmeaParser {
  double? _lat;
  double? _lon;
  int _quality = 0;
  int _sats = 0;
  double _hdop = 0;
  bool _rmcStatus = false;
  double _speedKnots = 0;
  double _course = 0;
  DateTime? _utc;

  /// Feed one raw NMEA line (e.g. `$GNRMC,123519,A,4807.038,N,01131.000,E,...`).
  /// Returns a merged fix when the line carried position data, else null.
  NmeaFix? push(String line) {
    if (line.isEmpty || line[0] != r'$') return null;
    // Sentence type after the talker id: "$GPGGA" / "$GNRMC" → type at [3..6).
    final type = line.length >= 6 ? line.substring(3, 6) : '';
    if (type == 'GGA') return _parseGga(line);
    if (type == 'RMC') return _parseRmc(line);
    return null;
  }

  NmeaFix? _parseGga(String line) {
    // $GPGGA,time,lat,N,lon,E,quality,sats,hdop,...
    final f = line.split(',');
    if (f.length < 9) return null;
    final lat = _parseLatLon(f[2], f[3]);
    final lon = _parseLatLon(f[4], f[5]);
    if (lat == null || lon == null) return null;
    _lat = lat;
    _lon = lon;
    _quality = int.tryParse(f[6]) ?? 0;
    _sats = int.tryParse(f[7]) ?? 0;
    _hdop = double.tryParse(f[8]) ?? 0;
    return _build();
  }

  NmeaFix? _parseRmc(String line) {
    // $GPRMC,time,A,lat,N,lon,E,speedKnots,course,date,...
    final f = line.split(',');
    if (f.length < 9) return null;
    _rmcStatus = f[2] == 'A';
    final lat = _parseLatLon(f[3], f[4]);
    final lon = _parseLatLon(f[5], f[6]);
    if (lat != null && lon != null) {
      _lat = lat;
      _lon = lon;
    }
    _speedKnots = double.tryParse(f[7]) ?? 0;
    _course = double.tryParse(f[8]) ?? 0;
    _utc = _parseTime(f[1], f.length > 9 ? f[9] : '');
    return _build();
  }

  NmeaFix _build() {
    final hasPos = _lat != null && _lon != null;
    final valid = hasPos && (_quality > 0 || _rmcStatus);
    return NmeaFix(
      valid: valid,
      lat: _lat ?? 0,
      lon: _lon ?? 0,
      speedMps: _speedKnots * 0.514444,
      heading: _course % 360,
      quality: _quality,
      sats: _sats,
      hdop: _hdop,
      timeUtc: _utc,
    );
  }

  /// Parse NMEA "ddmm.mmmm" (optionally with N/S/E/W hemisphere) → degrees.
  static double? _parseLatLon(String raw, String hemi) {
    if (raw.isEmpty) return null;
    final v = double.tryParse(raw);
    if (v == null || v.isNaN) return null;
    final deg = (v / 100).floorToDouble();
    final min = v - deg * 100;
    var out = deg + min / 60.0;
    if (hemi == 'S' || hemi == 'W') out = -out;
    return out;
  }

  /// "hhmmss" + "ddmmyy" (UTC) → DateTime. Returns null when malformed.
  static DateTime? _parseTime(String hhmmss, String ddmmyy) {
    if (hhmmss.length < 6) return null;
    final h = int.tryParse(hhmmss.substring(0, 2));
    final mi = int.tryParse(hhmmss.substring(2, 4));
    final s = int.tryParse(hhmmss.substring(4, 6));
    if (h == null || mi == null || s == null) return null;
    var day = 1, month = 1, year = 1970;
    if (ddmmyy.length >= 6) {
      day = int.tryParse(ddmmyy.substring(0, 2)) ?? 1;
      month = int.tryParse(ddmmyy.substring(2, 4)) ?? 1;
      year = 2000 + (int.tryParse(ddmmyy.substring(4, 6)) ?? 0);
    }
    try {
      return DateTime.utc(year, month, day, h, mi, s);
    } catch (_) {
      return null;
    }
  }
}
