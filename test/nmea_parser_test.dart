import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/core/nmea_parser.dart';

void main() {
  group('NmeaParser', () {
    test('merges GGA + RMC into a valid fix', () {
      final p = NmeaParser();
      // Bến Thành HCMC: 10°43.643'N 106°42.066'E
      final gga = p.push(
        r'$GPGGA,073510,1043.643,N,10642.066,E,1,12,1.2,8.1,M,,M,,*4F',
      );
      final rmc = p.push(
        r'$GPRMC,073510,A,1043.643,N,10642.066,E,10.5,125.0,280828,,,A*7D',
      );
      expect(gga, isNotNull);
      expect(gga!.valid, isTrue);
      expect(gga.quality, 1);
      expect(gga.sats, 12);
      // 10 + 43.643/60 = 10.72738..., 106 + 42.066/60 = 106.7011...
      expect(gga.lat, closeTo(10 + 43.643 / 60, 1e-4));
      expect(gga.lon, closeTo(106 + 42.066 / 60, 1e-4));
      expect(rmc, isNotNull);
      expect(rmc!.valid, isTrue);
      expect(rmc.speedMps, closeTo(10.5 * 0.514444, 0.001)); // knots → m/s
      expect(rmc.heading, closeTo(125.0, 0.001));
    });

    test('RMC status V (invalid) → fix not valid', () {
      final p = NmeaParser();
      final f = p.push(
        r'$GPRMC,073510,V,1043.643,N,10642.066,E,0.0,0.0,280828,,,N*78',
      );
      expect(f, isNotNull);
      expect(f!.valid, isFalse);
    });

    test('accuracy estimate scales with HDOP', () {
      final p = NmeaParser();
      final f = p.push(
        r'$GPGGA,073510,1043.643,N,10642.066,E,1,12,2.0,8.1,M,,M,,*4F',
      );
      expect(f, isNotNull);
      expect(f!.accuracyMeters, closeTo(12.0, 1e-9)); // hdop 2.0 × 6
    });

    test('south/west hemispheres are negated', () {
      final p = NmeaParser();
      final f = p.push(
        r'$GPGGA,073510,1043.643,S,10642.066,W,1,8,1.0,8.1,M,,M,,*46',
      );
      expect(f, isNotNull);
      expect(f!.lat, lessThan(0));
      expect(f.lon, lessThan(0));
    });

    test('GNGGA/GNRMC (GNSS talker) also parse', () {
      final p = NmeaParser();
      final gga = p.push(
        r'$GNGGA,073510,1043.643,N,10642.066,E,1,14,0.9,8.1,M,,M,,*4E',
      );
      final rmc = p.push(
        r'$GNRMC,073510,A,1043.643,N,10642.066,E,3.2,90.0,280828,,,A*7C',
      );
      expect(gga, isNotNull);
      expect(gga!.valid, isTrue);
      expect(gga.sats, 14);
      expect(rmc, isNotNull);
      expect(rmc!.valid, isTrue);
    });
  });
}
