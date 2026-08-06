/// Current weather via Open-Meteo — free, no API key (same pattern as the
/// SRTM elevation service). Used by the nav bottom status bar.
///
/// All fetches are async (non-blocking "background" HTTP calls) and
/// best-effort — a failure simply returns null and is never fatal. The nav
/// page runs these on a periodic timer (a de-facto background thread) so the
/// UI never stalls on network I/O.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

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

/// Current air temperature (°C) at [lat]/[lng], or null on failure.
/// Best-effort info — never fatal.
Future<double?> fetchCurrentTemperature(double lat, double lng) async {
  final w = await fetchWeather(lat, lng);
  return w?.tempC;
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
      'precipitation,weather_code',
    );
    final res = await http
        .get(url, headers: const {'User-Agent': 'navbridge/1.0 (weather)'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final cur = data['current'] as Map?;
    if (cur == null) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
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
    );
  } catch (_) {
    return null;
  }
}
