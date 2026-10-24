import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/weather.dart';

/// Windy point-forecast parsing.
///
/// The payload below is a REAL response from
/// `POST https://api.windy.com/api/point-forecast/v2` (model `gfs`, levels
/// `surface`) captured 2026-10-13 — key names, `units` map and values verbatim
/// (only the series shortened to three 3-hourly steps, which is what the
/// endpoint returns). It pins the three defects the live API exposed:
///
///   1. `weatherWarnings` is not an allowed GFS parameter — asking for it 400s
///      the WHOLE call, which is why Windy silently never answered and the app
///      fell through to the nearest airport's METAR.
///   2. `temp` is KELVIN (`units: {'temp-surface': 'K'}`) — read as °C it showed
///      299 °C.
///   3. `past3hprecip` is METRES — read as mm it was 1000× too small.
void main() {
  const now = 1791851000000; // 1 h after the series' 2nd step
  final realResponse = <String, dynamic>{
    'ts': [1791838800000, 1791850800000, 1791862800000],
    'units': {
      'temp-surface': 'K',
      'wind_u-surface': 'm*s-1',
      'wind_v-surface': 'm*s-1',
      'rh-surface': '%',
      'ptype-surface': null,
      'lclouds-surface': '%',
      'mclouds-surface': '%',
      'hclouds-surface': '%',
      'past3hprecip-surface': 'm',
      'pressure-surface': 'Pa',
      'dewpoint-surface': 'K',
    },
    'warning':
        'The testing API version is for development purposes only. This data is '
        'randomly shuffled and slightly modified.',
    'temp-surface': [299.4676585201401, 303.8364914898399, 298.9554012796625],
    'rh-surface': [88.26514945768803, 94.96789958556174, 87.53645972525588],
    'ptype-surface': [0, 1, 1],
    'lclouds-surface': [72.4216168706341, 81.09407391583183, 76.39608874782809],
    'mclouds-surface': [98.6927188940093, 0, 0.8254402294991408],
    'hclouds-surface': [100, 80.67060640278446, 92.04170293282829],
    'past3hprecip-surface': [
      0.0010908635120700147,
      9.276517838070292e-05,
      5.337936338388387e-05,
    ],
    'wind_u-surface': [
      -1.4275233696222371,
      -1.489220107700191,
      -1.289482200427649,
    ],
    'wind_v-surface': [
      1.862110156243472,
      -1.6715923120795395,
      1.7262369897794576,
    ],
  };

  test('the sample nearest NOW is used (the series starts in the past)', () {
    final w = windyInfoFromJson(realResponse, nowMs: now);
    expect(w, isNotNull);
    // Index 1 = 303.837 K, index 0 = 299.468 K, index 2 = 298.955 K.
    expect(w!.tempC, closeTo(303.8365 - 273.15, 0.01));
  });

  test('Kelvin is converted to Celsius via the response units map', () {
    final w = windyInfoFromJson(realResponse, nowMs: now)!;
    expect(w.tempC, closeTo(30.69, 0.02), reason: '303.84 K = 30.7 °C');
    expect(w.feelsLikeC, w.tempC);
    // A response that already says °C must NOT be shifted by 273.
    final celsius = Map<String, dynamic>.from(realResponse)
      ..['units'] = {'temp-surface': 'C'};
    expect(
      windyInfoFromJson(celsius, nowMs: now)!.tempC,
      closeTo(303.8365, 0.01),
    );
  });

  test('precipitation metres → mm', () {
    final w = windyInfoFromJson(realResponse, nowMs: now)!;
    // 9.2765e-05 m = 0.0928 mm.
    expect(w.precipMm, closeTo(0.09277, 0.0005));
  });

  test('wind u/v → km/h and the direction the wind comes FROM', () {
    final w = windyInfoFromJson(realResponse, nowMs: now)!;
    // sqrt(1.48922² + 1.67159²) = 2.239 m/s = 8.06 km/h.
    expect(w.windKmh, closeTo(8.06, 0.05));
    expect(w.windDir, closeTo(41.8, 0.5));
  });

  test('the WMO code is derived from ptype + cloud cover', () {
    final w = windyInfoFromJson(realResponse, nowMs: now)!;
    expect(w.weatherCode, 61, reason: 'ptype = 1 (rain)');
    expect(w.humidityPct, closeTo(94.97, 0.01));
    expect(w.source, 'Windy');

    expect(windyWmoCode(ptype: 2), 71, reason: 'snow');
    expect(windyWmoCode(ptype: 3), 66, reason: 'freezing rain');
    expect(windyWmoCode(ptype: 0, cloudPct: const [100, 100, 100]), 3);
    expect(windyWmoCode(ptype: 0, cloudPct: const [50, 50, 50]), 2);
    expect(windyWmoCode(ptype: 0, cloudPct: const [20, 20, 20]), 1);
    expect(windyWmoCode(ptype: 0, cloudPct: const [2, 3, 0]), 0);
    expect(
      windyWmoCode(),
      0,
      reason: 'nothing known → clear (Open-Meteo fills)',
    );
  });

  test(
    'a payload with no timeline is rejected (never a half-filled sample)',
    () {
      expect(windyInfoFromJson(const {'units': {}}, nowMs: now), isNull);
      expect(windyInfoFromJson(const {'ts': []}, nowMs: now), isNull);
    },
  );

  group('METAR is a NEIGHBOURHOOD source', () {
    // Real ICAO stations, from _vnAirports.
    final batch = <Map<String, dynamic>>[
      {'icao': 'VVTS', 'lat': 10.8188, 'lon': 106.6520, 'temp': 29.0},
      {'icao': 'VVDN', 'lat': 16.0439, 'lon': 108.1994, 'temp': 26.0},
    ];

    test('picks the nearest station when it is inside the radius', () {
      // Tân Phú, HCMC — Tân Sơn Nhất is ~4 km away.
      final m = nearestMetarWithin(batch, 10.7903, 106.6374);
      expect(m?['icao'], 'VVTS');
    });

    test('returns null when the nearest station is another province away', () {
      // Pleiku: Đà Nẵng is ~250 km, so its METAR says nothing about here.
      expect(nearestMetarWithin(batch, 13.9833, 108.0000), isNull);
      expect(
        nearestMetarWithin(
          batch,
          13.9833,
          108.0000,
          maxMeters: 400000,
        )?['icao'],
        'VVDN',
      );
    });

    test('a station 23 km away no longer describes the road', () {
      // Biên Hòa is ~23 km from Tân Sơn Nhất. The old 60 km radius used the
      // airport's rain/temperature there; 15 km keeps it local.
      expect(nearestMetarWithin(batch, 10.95, 106.82), isNull);
      expect(
        nearestMetarWithin(batch, 10.95, 106.82, maxMeters: 60000)?['icao'],
        'VVTS',
      );
    });

    test('skips entries with no temperature', () {
      final m = nearestMetarWithin(
        const [
          {'icao': 'VVTX', 'lat': 10.79, 'lon': 106.63},
        ],
        10.7903,
        106.6374,
      );
      expect(m, isNull);
    });
  });

  group('the Windy key precedence', () {
    test('a key pasted in Settings wins over the build-time define', () {
      expect(pickWindyApiKey(stored: 'abc', buildTime: 'env'), 'abc');
      expect(pickWindyApiKey(stored: '  abc  ', buildTime: 'env'), 'abc');
    });

    test('falls back to the build-time define when nothing is stored', () {
      expect(pickWindyApiKey(stored: null, buildTime: 'env'), 'env');
      expect(pickWindyApiKey(stored: '', buildTime: 'env'), 'env');
      expect(pickWindyApiKey(stored: '   ', buildTime: 'env'), 'env');
    });

    test('no key anywhere → Windy off (the chain falls through)', () {
      expect(pickWindyApiKey(stored: null, buildTime: ''), isEmpty);
    });
  });

  group('METAR weather codes are local to the station', () {
    test('vicinity showers/thunder are not rain at the car', () {
      expect(
        metarWeatherCode({
          'wxcodes': ['VCSH'],
          'clouds': [
            {'cover': 'BKN'},
          ],
        }),
        3,
      );
      expect(
        metarWeatherCode({
          'wxcodes': ['VCTS'],
          'clouds': [
            {'cover': 'SCT'},
          ],
        }),
        2,
      );
    });

    test('NSW is dry, not "some other precipitation"', () {
      expect(
        metarWeatherCode({
          'wxcodes': ['NSW'],
          'clouds': [
            {'cover': 'FEW'},
          ],
        }),
        1,
      );
    });

    test('rain at the station still wins, even next to a vicinity code', () {
      expect(
        metarWeatherCode({
          'wxcodes': ['-RA'],
        }),
        61,
      );
      expect(
        metarWeatherCode({
          'wxcodes': ['VCSH', '-RA'],
        }),
        61,
      );
      expect(
        metarWeatherCode({
          'wxcodes': ['+TSRA'],
        }),
        95,
      );
    });
  });

  group('the published weather code', () {
    test('point sources beat a coarse source that reports rain', () {
      // Open-Meteo at the car says clear; an airport METAR 23 km away says
      // rain. The car is dry.
      expect(pickWeatherCodePreferPoint(point: [0], coarse: [61]), 0);
      expect(pickWeatherCodePreferPoint(point: [0], coarse: [80]), 0);
    });

    test(
      'point sources still promote precipitation within their own group',
      () {
        expect(pickWeatherCodePreferPoint(point: [0, 51], coarse: [0]), 51);
      },
    );

    test('coarse codes are used only when no point source answered', () {
      expect(pickWeatherCodePreferPoint(point: [null], coarse: [80]), 80);
      expect(pickWeatherCodePreferPoint(point: [null], coarse: [null]), isNull);
    });

    test('any source reporting precipitation wins', () {
      // Windy (the authority) says dry, Open-Meteo says drizzle → the drizzle
      // stands. Without this, activating Windy would silence the rain
      // announcements, because Windy's code comes from a 3-hourly `ptype`.
      expect(pickWeatherCode([0, 51]), 51);
      expect(pickWeatherCode([61, 0]), 61);
      expect(pickWeatherCode([null, 80]), 80);
      expect(pickWeatherCode([0, 0, 95]), 95);
      expect(pickWeatherCode([0, 71]), 71, reason: 'snow is precipitation too');
    });

    test('with nothing precipitating, the authority keeps the code', () {
      expect(pickWeatherCode([3, 0]), 3);
      expect(pickWeatherCode([null, 1]), 1);
      expect(pickWeatherCode([null, null]), isNull);
      expect(pickWeatherCode(const []), isNull);
    });

    test('isPrecipCode covers rain, snow, showers and storms', () {
      expect(isPrecipCode(51), isTrue);
      expect(isPrecipCode(67), isTrue);
      expect(isPrecipCode(71), isTrue);
      expect(isPrecipCode(86), isTrue);
      expect(isPrecipCode(95), isTrue);
      expect(isPrecipCode(3), isFalse);
      expect(isPrecipCode(48), isFalse, reason: 'fog is not precipitation');
      expect(isPrecipCode(null), isFalse);
    });
  });
}
