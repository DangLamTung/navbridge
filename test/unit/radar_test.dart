import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/services/radar.dart';
import 'package:navbridge/services/weather.dart';

void main() {
  group('radarTileUrl', () {
    test('builds the RainViewer tile template', () {
      const d = RadarData(
        host: 'https://tilecache.rainviewer.com',
        past: [],
        nowcast: [],
      );
      const f = RadarFrame(time: 1000, path: '/v2/radar/abc123');
      expect(
        radarTileUrl(d, f),
        'https://tilecache.rainviewer.com/v2/radar/abc123/512/{z}/{x}/{y}/4/1_1.png',
      );
    });
  });

  group('satelliteTileUrl', () {
    test('builds the RainViewer satellite (infrared) tile template', () {
      const d = RadarData(
        host: 'https://tilecache.rainviewer.com',
        past: [],
        nowcast: [],
      );
      const f = RadarFrame(time: 1000, path: '/v2/satellite/abc123');
      expect(
        satelliteTileUrl(d, f),
        'https://tilecache.rainviewer.com/v2/satellite/abc123/512/{z}/{x}/{y}/1/1_1.png',
      );
    });
  });

  group('nasaCloudTileUrl', () {
    test(
      'builds a GIBS Himawari tile template with a 40-min-old rounded time',
      () {
        final now = DateTime.utc(2026, 8, 22, 2, 37, 5);
        final url = nasaCloudTileUrl(now: now);
        // 40 min back = 01:57 → rounded down to the 10-min mark 01:50.
        expect(
          url,
          contains(
            'Himawari_AHI_Band13_Clean_Infrared/default/'
            '2026-08-22T01:50:00Z/GoogleMapsCompatible_Level6/{z}/{y}/{x}.png',
          ),
        );
      },
    );
  });

  group('RadarData satellite', () {
    test('hasSatellite reflects the infrared frames', () {
      const empty = RadarData(host: 'h', past: [], nowcast: []);
      expect(empty.hasSatellite, isFalse);
      const withSat = RadarData(
        host: 'h',
        past: [],
        nowcast: [],
        satellite: [RadarFrame(time: 1, path: '/v2/satellite/x')],
      );
      expect(withSat.hasSatellite, isTrue);
    });
  });

  group('radarFrameLabel', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1_000_000_000_000);
    test('labels the latest frame as Hiện tại', () {
      // Frame 90 s ago → within the 5-min window.
      expect(
        radarFrameLabel(
          RadarFrame(time: 1_000_000_000 - 90, path: ''),
          now: now,
        ),
        'Hiện tại',
      );
    });
    test('labels past and future frames with minutes', () {
      expect(
        radarFrameLabel(
          RadarFrame(time: 1_000_000_000 - 20 * 60, path: ''),
          now: now,
        ),
        '20p',
      );
      expect(
        radarFrameLabel(
          RadarFrame(time: 1_000_000_000 + 10 * 60, path: ''),
          now: now,
        ),
        '+10p',
      );
    });
  });

  group('WeatherInfo.rainProbSoon', () {
    test('max of the next two hours', () {
      const w = WeatherInfo(tempC: 30, rainProb: [6, 0, 0]);
      expect(w.rainProbSoon, 6);
      const w2 = WeatherInfo(tempC: 30, rainProb: [10, 80, 0]);
      expect(w2.rainProbSoon, 80);
    });
    test('null when no probability', () {
      const w = WeatherInfo(tempC: 30);
      expect(w.rainProbSoon, isNull);
    });
  });
}
