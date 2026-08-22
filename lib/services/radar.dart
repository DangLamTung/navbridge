/// Rain radar overlay — RainViewer's free public Weather Maps API (no key).
///
/// Fetches the radar frame index (2 h of past frames at 10-min steps, plus a
/// `nowcast` forecast when the radar network is live — often empty), and
/// builds tile URLs the map renderers can display. All calls are async and
/// best-effort: a failure returns null and is never fatal (the app keeps
/// working without the radar overlay).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// One radar frame (a snapshot of the rain map at [time]).
class RadarFrame {
  final int time; // Unix seconds (UTC)
  final String path; // e.g. "/v2/radar/1a2b3c"
  const RadarFrame({required this.time, required this.path});
}

/// The radar frame index: host + past/nowcast frames + a DISTINCT weather-
/// satellite (infrared cloud) frame list.
class RadarData {
  final String host;
  final List<RadarFrame> past;
  final List<RadarFrame> nowcast;

  /// Weather-satellite (infrared) frames — clouds, not precipitation. This
  /// is a separate layer from the radar; the feed often has no satellite
  /// product (e.g. at night), so it may be empty.
  final List<RadarFrame> satellite;

  const RadarData({
    required this.host,
    required this.past,
    required this.nowcast,
    this.satellite = const [],
  });
  bool get hasFrames => past.isNotEmpty || nowcast.isNotEmpty;
  bool get hasSatellite => satellite.isNotEmpty;
}

/// Fetch the radar frame index. Returns null on any failure (offline, 5xx,
/// parse error). The result is cached by the caller (~5 min).
Future<RadarData?> fetchRadarData() async {
  try {
    final res = await http
        .get(Uri.parse('https://api.rainviewer.com/public/weather-maps.json'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final radar = j['radar'] as Map<String, dynamic>?;
    if (radar == null) return null;
    final host = (j['host'] as String?) ?? 'https://tilecache.rainviewer.com';
    List<RadarFrame> parse(String key) => [
      for (final f in (radar[key] as List? ?? const []))
        if (f is Map && f['time'] is num && f['path'] is String)
          RadarFrame(
            time: (f['time'] as num).toInt(),
            path: f['path'] as String,
          ),
    ];
    List<RadarFrame> satelliteFrames() {
      final sat = radar['satellite'] as Map<String, dynamic>?;
      return [
        for (final f in ((sat?['infrared']) as List? ?? const []))
          if (f is Map && f['time'] is num && f['path'] is String)
            RadarFrame(
              time: (f['time'] as num).toInt(),
              path: f['path'] as String,
            ),
      ];
    }

    return RadarData(
      host: host,
      past: parse('past'),
      nowcast: parse('nowcast'),
      satellite: satelliteFrames(),
    );
  } catch (_) {
    return null;
  }
}

/// Map-tile URL template for [frame]. `{z}/{x}/{y}` are filled by the map
/// renderer. Color scheme `4` = "Universal Blue"; options `1_1` = smoothed +
/// snow colors. Radar tiles are low-zoom (z0–7) and upscale at higher zooms.
String radarTileUrl(RadarData d, RadarFrame f) =>
    '${d.host}${f.path}/256/{z}/{x}/{y}/4/1_1.png';

/// Map-tile URL template for a weather-SATELLITE [frame] (infrared clouds).
/// Same `{host}{path}/{size}/{z}/{x}/{y}/{color}/{options}` shape as radar;
/// color scheme `1` = infrared. Satellite tiles are low-zoom (z0–7) too.
String satelliteTileUrl(RadarData d, RadarFrame f) =>
    '${d.host}${f.path}/256/{z}/{x}/{y}/1/1_1.png';

/// NASA GIBS current cloud-imagery tile URL template (Himawari-9 AHI Band 13
/// "clean infrared" over Asia-Pacific — covers Việt Nam). Used as a FALLBACK
/// when RainViewer's satellite feed is empty (which it often is), so the
/// weather-satellite layer always has clouds to show. `{z}/{y}/{x}` are
/// filled by the map renderer. The time is ~40 min in the past, rounded to a
/// 10-min mark — GIBS lags the latest frames, so a too-recent time returns no
/// tiles. Tiles exist only up to z6 (GoogleMapsCompatible_Level6).
String nasaCloudTileUrl({DateTime? now}) {
  final t = now ?? DateTime.now().toUtc();
  final past = t.subtract(const Duration(minutes: 40));
  final rounded = DateTime.utc(
    past.year,
    past.month,
    past.day,
    past.hour,
    (past.minute ~/ 10) * 10,
  );
  final time = '${rounded.toIso8601String().split('.').first}Z';
  return 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/'
      'Himawari_AHI_Band13_Clean_Infrared/default/$time/'
      'GoogleMapsCompatible_Level6/{z}/{y}/{x}.png';
}

/// Short label for a frame relative to now: "Hiện tại", "-20p", "+10p"…
String radarFrameLabel(RadarFrame f, {DateTime? now}) {
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final mins = (f.time - t) ~/ 60;
  if (mins.abs() < 5) return 'Hiện tại';
  return mins <= 0 ? '${mins.abs()}p' : '+${mins}p';
}
