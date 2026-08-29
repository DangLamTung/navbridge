import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BLE Auto Connect Settings', () {
    test('AppSettings defaults enable bleAutoConnect with empty device', () {
      const s = AppSettings();
      expect(s.bleAutoConnect, isTrue);
      expect(s.lastBleMac, isEmpty);
      expect(s.lastBleName, isEmpty);
      expect(s.lastBleType, equals('auto'));
    });

    test('AppSettings serializes and preserves BLE auto-connect fields', () {
      const s = AppSettings(
        bleAutoConnect: true,
        lastBleMac: 'AA:BB:CC:DD:EE:FF',
        lastBleName: 'EINK-CLOCK-585',
        lastBleType: 'clock',
      );
      final json = s.toJson();
      expect(json['bleAutoConnect'], isTrue);
      expect(json['lastBleMac'], equals('AA:BB:CC:DD:EE:FF'));
      expect(json['lastBleName'], equals('EINK-CLOCK-585'));
      expect(json['lastBleType'], equals('clock'));
    });

    test(
      'AppSettings handles disabled bleAutoConnect and MAP display type',
      () {
        const s = AppSettings(
          bleAutoConnect: false,
          lastBleMac: '11:22:33:44:55:66',
          lastBleName: 'NAV-OSM-28',
          lastBleType: 'map',
        );
        final json = s.toJson();
        expect(json['bleAutoConnect'], isFalse);
        expect(json['lastBleMac'], equals('11:22:33:44:55:66'));
        expect(json['lastBleName'], equals('NAV-OSM-28'));
        expect(json['lastBleType'], equals('map'));
      },
    );
  });
}
