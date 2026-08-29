/// Current weather via Open-Meteo — free, no API key (same pattern as the
/// SRTM elevation service). Used by the nav bottom status bar.
///
/// All fetches are async (non-blocking "background" HTTP calls) and
/// best-effort — a failure simply returns null and is never fatal. The nav
/// page runs these on a periodic timer (a de-facto background thread) so the
/// UI never stalls on network I/O.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Windy Point Forecast API key — from `--dart-define=WINDY_API_KEY` (.env).
/// Empty = Windy disabled (the app falls back to the free sources).
const String windyApiKey = String.fromEnvironment('WINDY_API_KEY');

/// Current weather at a location. Nullable fields are null when the feed
/// doesn't include them (or the call failed).
class WeatherInfo {
  const WeatherInfo({
    this.tempC,
    this.feelsLikeC,
    this.humidityPct,
    this.windKmh,
    this.windDir,
    this.precipMm,
    this.weatherCode,
    this.rainProb,
    this.source,
  });

  /// Air temperature (°C).
  final double? tempC;

  /// Perceived temperature (°C) — "cảm giác".
  final double? feelsLikeC;

  /// Relative humidity (%).
  final double? humidityPct;

  /// Wind speed (km/h).
  final double? windKmh;

  /// Wind direction (degrees, meteorological).
  final double? windDir;

  /// Precipitation in the last hour (mm).
  final double? precipMm;

  /// Open-Meteo WMO weather code (0 clear .. 95+ thunder) — mapped to an
  /// emoji by [weatherEmoji].
  final int? weatherCode;

  /// Hourly rain probability (%) for the next few hours (Open-Meteo
  /// `precipitation_probability`, null when unavailable).
  final List<int>? rainProb;

  /// Source tag (e.g. 'Windy') for attribution; null = Open-Meteo.
  final String? source;

  /// Best-guess rain probability (%) within the next ~2 h — the max of the
  /// current + next hour entries (null when the feed has no probability).
  int? get rainProbSoon {
    final p = rainProb;
    if (p == null || p.isEmpty) return null;
    return p.take(2).reduce((a, b) => a > b ? a : b);
  }
}

/// A compact weather emoji for an Open-Meteo WMO [code] (0 = clear, 1-3 =
/// clouds, 45/48 = fog, 51-67 = rain, 71-77 = snow, 80-86 = showers,
/// 95+ = thunder). Falls back to a thermometer when the code is unknown.
String weatherEmoji(int? code) {
  if (code == null) return '🌡️';
  if (code == 0) return '☀️';
  if (code <= 2) return '⛅';
  if (code == 3) return '☁️';
  if (code == 45 || code == 48) return '🌫️';
  if (code <= 57) return '🌦️';
  if (code <= 67) return '🌧️';
  if (code <= 77) return '🌨️';
  if (code <= 82) return '🌦️';
  if (code <= 86) return '🌨️';
  return '⛈️';
}

/// A short ASCII label for an Open-Meteo WMO [code] — the ESP banner font is
/// ASCII-only, so no emoji. Falls back to "Clear".
String weatherTextForCode(int? code) {
  if (code == null) return 'Clear';
  if (code == 0) return 'Clear';
  if (code <= 2) return 'Cloudy';
  if (code == 3) return 'Overcast';
  if (code == 45 || code == 48) return 'Fog';
  if (code <= 57) return 'Drizzle';
  if (code <= 67) return 'Rain';
  if (code <= 77) return 'Snow';
  if (code <= 82) return 'Showers';
  if (code <= 86) return 'Snow';
  return 'Storm';
}

/// A compact HOURLY rain timeline for the AI assistant, so it can answer
/// "mưa tạnh lúc mấy giờ": e.g. "13h 80%, 14h 40%, 15h 10%". Each entry is
/// the rain probability (%) for the current hour, +1h, +2h… (from the hourly
/// forecast, oldest first). Empty when the feed has no probability.
String rainTimelineText(List<int>? probs) {
  if (probs == null || probs.isEmpty) return '';
  final nowH = DateTime.now().hour;
  final parts = <String>[];
  for (var i = 0; i < probs.length && i < 6; i++) {
    final h = (nowH + i) % 24;
    parts.add('${h.toString().padLeft(2, '0')}h ${probs[i]}%');
  }
  return parts.join(', ');
}

/// Current air temperature (°C) at [lat]/[lng], or null on failure.
/// Best-effort info — never fatal.
Future<double?> fetchCurrentTemperature(double lat, double lng) async {
  final w = await fetchWeather(lat, lng);
  return w?.tempC;
}

/// Merge several [WeatherInfo] samples (fetched at points along the route
/// ahead) into ONE "weather ahead" summary: the most severe weather code wins
/// (storm > snow > rain > drizzle > fog > clouds > clear), and the
/// temperature is averaged across the samples. Used by the PiP window / nav UI
/// to show what's coming a few km down the road, not just at the car.
WeatherInfo? mergeWeatherAhead(Iterable<WeatherInfo> samples) {
  final list = samples.toList();
  if (list.isEmpty) return null;
  int severity(int? code) {
    if (code == null) return 0;
    if (code >= 95) return 9; // thunder
    if (code >= 80) return 8; // showers
    if (code >= 71) return 7; // snow
    if (code >= 61) return 6; // rain
    if (code >= 51) return 5; // drizzle
    if (code == 45 || code == 48) return 4; // fog
    if (code == 3) return 3; // overcast
    if (code <= 2) return 2; // cloudy
    if (code == 0) return 1; // clear
    return 0;
  }

  var worst = list.first;
  for (final w in list.skip(1)) {
    if (severity(w.weatherCode) > severity(worst.weatherCode)) worst = w;
  }
  final temps = list
      .map((w) => w.tempC)
      .whereType<double>()
      .toList(growable: false);
  return WeatherInfo(
    tempC: temps.isEmpty
        ? worst.tempC
        : temps.reduce((a, b) => a + b) / temps.length,
    feelsLikeC: worst.feelsLikeC,
    humidityPct: worst.humidityPct,
    windKmh: worst.windKmh,
    windDir: worst.windDir,
    precipMm: worst.precipMm,
    weatherCode: worst.weatherCode,
    rainProb: worst.rainProb,
  );
}

/// Current weather at [lat]/[lng], or null on failure. Fetched asynchronously
/// (a background HTTP call) so the nav UI never blocks on it.
Future<WeatherInfo?> fetchWeather(double lat, double lng) async {
  try {
    final url = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lng'
      '&current=temperature_2m,apparent_temperature,'
      'relative_humidity_2m,wind_speed_10m,wind_direction_10m,'
      'precipitation,weather_code'
      // Hourly rain probability — the "sắp mưa không?" prediction. 8 hours so
      // the AI can also answer "mưa tạnh lúc mấy giờ" (see [rainTimelineText]).
      '&hourly=precipitation_probability,precipitation'
      '&forecast_hours=8',
    );
    final res = await http
        .get(url, headers: const {'User-Agent': 'navbridge/1.0 (weather)'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final cur = data['current'] as Map?;
    if (cur == null) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
    // Hourly precipitation probability (%), oldest first.
    final hourly = data['hourly'] as Map?;
    List<int>? probs;
    if (hourly != null && hourly['precipitation_probability'] is List) {
      probs = (hourly['precipitation_probability'] as List)
          .whereType<num>()
          .map((e) => e.toInt())
          .toList(growable: false);
    }
    return WeatherInfo(
      tempC: d(cur['temperature_2m']),
      feelsLikeC: d(cur['apparent_temperature']),
      humidityPct: d(cur['relative_humidity_2m']),
      windKmh: d(cur['wind_speed_10m']),
      windDir: d(cur['wind_direction_10m']),
      precipMm: d(cur['precipitation']),
      weatherCode: cur['weather_code'] is num
          ? (cur['weather_code'] as num).toInt()
          : null,
      rainProb: probs,
    );
  } catch (_) {
    return null;
  }
}

/// Vietnamese airports that report METAR observations (ICAO, lat, lng) — the
/// nearest one gives REAL observed weather (free, no key) via aviationweather.
const List<(String, double, double)> _vnAirports = [
  ('VVTS', 10.818, 106.652), // Tân Sơn Nhất (TP.HCM)
  ('VVNB', 21.221, 105.807), // Nội Bài (Hà Nội)
  ('VVDN', 16.044, 108.199), // Đà Nẵng
  ('VVCR', 11.998, 109.219), // Cam Ranh (Khánh Hòa)
  ('VVCT', 10.085, 105.712), // Cần Thơ
  ('VVPQ', 10.169, 103.995), // Phú Quốc
  ('VVTH', 16.401, 107.703), // Phú Bài (Huế)
  ('VVPB', 17.515, 106.590), // Đồng Hới
  ('VVPC', 15.403, 108.706), // Chu Lai (Quảng Nam)
  ('VVDL', 11.751, 108.374), // Liên Khương (Đà Lạt)
  ('VVPK', 14.004, 108.017), // Pleiku
  ('VVCI', 20.818, 106.725), // Cát Bi (Hải Phòng)
  ('VVDH', 21.398, 103.008), // Điện Biên
];

List<Map<String, dynamic>>? _metarCache;
DateTime? _metarCacheAt;
const _metarCacheTtl = Duration(minutes: 5);

/// Fetch ALL Vietnamese airport METARs in one call (cached ~5 min; METARs
/// update every 30–60 min anyway). Empty on failure.
Future<List<Map<String, dynamic>>> _fetchMetarBatch() async {
  final now = DateTime.now();
  if (_metarCache != null && now.difference(_metarCacheAt!) < _metarCacheTtl) {
    return _metarCache!;
  }
  try {
    final ids = _vnAirports.map((a) => a.$1).join(',');
    final res = await http
        .get(
          Uri.parse(
            'https://aviationweather.gov/api/data/metar'
            '?format=json&ids=$ids',
          ),
          headers: const {'User-Agent': 'navbridge/1.0 (weather metar)'},
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const [];
    final d = jsonDecode(utf8.decode(res.bodyBytes));
    _metarCache = (d as List).cast<Map<String, dynamic>>();
    _metarCacheAt = now;
    return _metarCache!;
  } catch (_) {
    return const [];
  }
}

/// Real observed weather from the NEAREST reporting Vietnamese airport
/// (METAR — measured, not a forecast model): actual temperature / wind /
/// conditions. Free + keyless. Null when no station is reporting.
Future<WeatherInfo?> fetchMetarWeather(double lat, double lng) async {
  final batch = await _fetchMetarBatch();
  if (batch.isEmpty) return null;
  Map<String, dynamic>? best;
  var bestD = double.infinity;
  for (final m in batch) {
    final slat = (m['lat'] as num?)?.toDouble();
    final slon = (m['lon'] as num?)?.toDouble();
    if (slat == null || slon == null || m['temp'] is! num) continue;
    final dLat = (slat - lat) * 111320.0;
    final dLng = (slon - lng) * 111320.0 * math.cos(lat * math.pi / 180);
    final dd = math.sqrt(dLat * dLat + dLng * dLng);
    if (dd < bestD) {
      bestD = dd;
      best = m;
    }
  }
  if (best == null) return null;
  final temp = (best['temp'] as num).toDouble();
  final wdir = best['wdir'] is num ? (best['wdir'] as num).toDouble() : null;
  final wspdKt = best['wspd'] is num ? (best['wspd'] as num).toDouble() : null;
  return WeatherInfo(
    tempC: temp,
    feelsLikeC: temp, // METAR has no feels-like — use the measured temp
    windKmh: wspdKt == null ? null : wspdKt * 1.852, // knots → km/h
    windDir: wdir,
    weatherCode: _metarWeatherCode(best),
  );
}

int _cloudRank(String c) => switch (c) {
  'OVC' => 4,
  'BKN' => 3,
  'SCT' => 2,
  'FEW' => 1,
  _ => 0,
};

/// Map a METAR observation to an Open-Meteo-style WMO code (for the emoji).
int? _metarWeatherCode(Map<String, dynamic> m) {
  final wxcodes = (m['wxcodes'] as List?) ?? const [];
  final wx = wxcodes.join(' ').toUpperCase();
  if (wx.contains('TS') || wx.contains('VCTS')) return 95; // thunder
  if (wx.contains('SH')) return 80; // showers
  if (wx.contains('RA')) return 61; // rain
  if (wx.contains('DZ')) return 51; // drizzle
  if (wx.contains('SN')) return 71; // snow
  if (wx.contains('FG')) return 45; // fog
  if (wx.contains('BR') || wx.contains('HZ')) return 45; // mist / haze
  if (wx.isNotEmpty) return 61; // some other precipitation
  // No precipitation → derive from the highest cloud cover.
  var cover = '';
  for (final c in (m['clouds'] as List?) ?? const []) {
    final cv = (c as Map?)?['cover'] as String?;
    if (cv != null && _cloudRank(cv) > _cloudRank(cover)) cover = cv;
  }
  switch (cover) {
    case 'OVC':
    case 'BKN':
      return 3; // overcast
    case 'SCT':
      return 2; // partly cloudy
    case 'FEW':
      return 1;
    default:
      return 0; // clear
  }
}

/// Current weather from Windy (GFS point forecast) when a key is configured.
/// Returns null when there's no key or the call fails (callers fall back to
/// the free sources). Wind is u/v components (m/s) → km/h + meteorological
/// direction; the WMO [weatherWarnings] code feeds the existing emoji.
Future<WeatherInfo?> fetchWindyWeather(double lat, double lng) async {
  if (windyApiKey.isEmpty) return null;
  try {
    final res = await http
        .post(
          Uri.parse('https://api.windy.com/api/point-forecast/v2'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'lat': lat,
            'lon': lng,
            'model': 'gfs',
            'parameters': [
              'temp',
              'wind',
              'rh',
              'ptype',
              'lclouds',
              'mclouds',
              'hclouds',
              'weatherWarnings',
              'precip',
            ],
            'levels': ['surface'],
            'key': windyApiKey,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final ts = (d['ts'] as List?)?.cast<num>();
    if (ts == null || ts.isEmpty) return null;
    // Index of the forecast point closest to now.
    final now = DateTime.now().millisecondsSinceEpoch;
    var idx = 0;
    var bestD = double.infinity;
    for (var i = 0; i < ts.length; i++) {
      final dd = (ts[i].toDouble() - now).abs();
      if (dd < bestD) {
        bestD = dd;
        idx = i;
      }
    }
    double? at(String key) {
      final arr = d[key] as List?;
      if (arr == null || idx >= arr.length) return null;
      final v = arr[idx];
      return v is num ? v.toDouble() : null;
    }

    final u = at('wind_u-surface');
    final v = at('wind_v-surface');
    double? windKmh;
    double? windDir;
    if (u != null && v != null) {
      windKmh = math.sqrt(u * u + v * v) * 3.6; // m/s → km/h
      // Meteorological direction the wind comes FROM (0 = N).
      windDir = (math.atan2(u, v) * 180 / math.pi + 180) % 360;
    }
    final wx = at('weatherwarnings-surface');
    final ptype = at('ptype-surface');
    final code = wx != null
        ? wx.round()
        : (ptype != null && ptype > 0)
        ? (ptype >= 5 ? 71 : 61)
        : null;
    return WeatherInfo(
      tempC: at('temp-surface'),
      feelsLikeC: at('temp-surface'),
      humidityPct: at('rh-surface'),
      windKmh: windKmh,
      windDir: windDir,
      precipMm: at('past3hprecip-surface'),
      weatherCode: code,
      source: 'Windy',
    );
  } catch (_) {
    return null;
  }
}

/// AccuWeather API key — real-time current conditions + 12-hour rain forecast.
/// Free tier ≈ 50 calls/day per endpoint. From `--dart-define=
/// ACCUWEATHER_API_KEY` (.env). Empty = AccuWeather disabled (the app uses
/// Windy → METAR → Open-Meteo).
const String accuWeatherApiKey = String.fromEnvironment('ACCUWEATHER_API_KEY');

/// AccuWeather WeatherIcon (1–44) → Open-Meteo WMO code, so the existing
/// emoji / merge / rain-ahead logic just works.
int? _accuIconToWmo(int icon) {
  if (icon <= 0) return null;
  if (icon == 1 || icon == 31 || icon == 32) return 0; // clear
  if (icon <= 5) return 1; // partly cloudy
  if (icon == 6 || icon == 7) return 2; // cloudy
  if (icon == 8 || icon == 35 || icon == 36) return 3; // overcast
  if (icon == 11) return 45; // fog
  if (icon == 12 || icon == 13 || icon == 14 || icon == 37 || icon == 38) {
    return 61; // rain
  }
  if (icon == 15 || icon == 16) return 95; // thunderstorm
  if (icon == 17 || icon == 18 || icon == 39 || icon == 40) {
    return 80; // showers
  }
  if (icon >= 19 && icon <= 26) return 71; // snow
  if (icon == 29 || icon == 30) return 51; // drizzle
  if (icon >= 41 && icon <= 44) return 73; // snow
  return null;
}

WeatherInfo? _accuCache;
double? _accuCacheLat;
double? _accuCacheLng;
DateTime? _accuCacheAt;
const _accuCacheTtl = Duration(minutes: 30);

/// Real-time current weather from AccuWeather (when a key is set): location
/// key lookup → current conditions + 12-hour rain probability. Cached
/// ~30 min so the free tier (~50 calls/day per endpoint) isn't blown by the
/// 3-min nav refresh. Best-effort: null on failure / no key (falls back to
/// Windy → METAR → Open-Meteo).
Future<WeatherInfo?> fetchAccuWeather(double lat, double lng) async {
  final key = accuWeatherApiKey;
  if (key.isEmpty) return null;
  final now = DateTime.now();
  if (_accuCache != null &&
      _accuCacheLat == lat &&
      _accuCacheLng == lng &&
      now.difference(_accuCacheAt!) < _accuCacheTtl) {
    return _accuCache;
  }
  try {
    // 1) Location key from the coordinates (geoposition search).
    final locRes = await http
        .get(
          Uri.parse(
            'https://dataservice.accuweather.com/locations/v1/cities/'
            'geoposition/search?apikey=$key&q=$lat,$lng&language=vi',
          ),
          headers: const {'User-Agent': 'navbridge/1.0 (accuweather)'},
        )
        .timeout(const Duration(seconds: 10));
    if (locRes.statusCode != 200) return null;
    final loc = jsonDecode(utf8.decode(locRes.bodyBytes)) as Map?;
    final locKey = loc?['Key'] as String?;
    if (locKey == null || locKey.isEmpty) return null;
    // 2) Current conditions.
    final curRes = await http
        .get(
          Uri.parse(
            'https://dataservice.accuweather.com/currentconditions/v1/'
            '$locKey?apikey=$key&language=vi&details=true',
          ),
          headers: const {'User-Agent': 'navbridge/1.0 (accuweather)'},
        )
        .timeout(const Duration(seconds: 10));
    if (curRes.statusCode != 200) return null;
    final curList = jsonDecode(utf8.decode(curRes.bodyBytes)) as List?;
    if (curList == null || curList.isEmpty) return null;
    final c = (curList.first as Map?) ?? const {};
    double? m(Object? v) => v is num ? v.toDouble() : null;
    final temp = m((c['Temperature'] as Map?)?['Metric']?['Value']);
    if (temp == null) return null;
    // 3) 12-hour rain probability ("sắp mưa không?").
    List<int>? probs;
    try {
      final fcRes = await http
          .get(
            Uri.parse(
              'https://dataservice.accuweather.com/forecasts/v1/hourly/12hour/'
              '$locKey?apikey=$key&language=vi&metric=true',
            ),
            headers: const {'User-Agent': 'navbridge/1.0 (accuweather)'},
          )
          .timeout(const Duration(seconds: 10));
      if (fcRes.statusCode == 200) {
        final fc = jsonDecode(utf8.decode(fcRes.bodyBytes)) as List?;
        probs = [
          for (final h in fc ?? const [])
            if (h is Map) (h['RainProbability'] as num?)?.toInt() ?? 0,
        ];
      }
    } catch (_) {}
    final icon = (c['WeatherIcon'] as num?)?.toInt();
    final info = WeatherInfo(
      tempC: temp,
      feelsLikeC: m((c['RealFeelTemperature'] as Map?)?['Metric']?['Value']),
      humidityPct: m(c['RelativeHumidity']),
      windKmh: m((c['Wind'] as Map?)?['Speed']?['Metric']?['Value']),
      windDir: m((c['Wind'] as Map?)?['Direction']?['Degrees']),
      precipMm: m(
        (c['PrecipitationSummary'] as Map?)?['PastHour']?['Metric']?['Value'],
      ),
      weatherCode: icon == null ? null : _accuIconToWmo(icon),
      rainProb: probs,
      source: 'AccuWeather',
    );
    _accuCache = info;
    _accuCacheLat = lat;
    _accuCacheLng = lng;
    _accuCacheAt = now;
    return info;
  } catch (_) {
    return null;
  }
}

/// Best current weather: AccuWeather (if a key is set) → Windy → real
/// observed METAR (nearest VN airport) → Open-Meteo. Open-Meteo fills the
/// fields the others lack (humidity, rain probability, forecast).
Future<WeatherInfo?> fetchBestWeather(double lat, double lng) async {
  final results = await Future.wait([
    fetchWeather(lat, lng),
    fetchMetarWeather(lat, lng),
    fetchWindyWeather(lat, lng),
    fetchAccuWeather(lat, lng),
  ]);
  final om = results[0];
  final metar = results[1];
  final windy = results[2];
  final accu = results[3];
  final primary = accu ?? windy ?? metar ?? om;
  if (primary == null) return null;
  return WeatherInfo(
    tempC: primary.tempC ?? om?.tempC,
    feelsLikeC: om?.feelsLikeC ?? primary.feelsLikeC,
    humidityPct: primary.humidityPct ?? om?.humidityPct,
    windKmh: primary.windKmh ?? om?.windKmh,
    windDir: primary.windDir ?? om?.windDir,
    precipMm: primary.precipMm ?? om?.precipMm,
    weatherCode: primary.weatherCode ?? om?.weatherCode,
    rainProb: om?.rainProb,
    source: primary.source,
  );
}
