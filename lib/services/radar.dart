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

/// The radar frame index: host + past/nowcast frames.
class RadarData {
  final String host;
  final List<RadarFrame> past;
  final List<RadarFrame> nowcast;
  const RadarData({
    required this.host,
    required this.past,
    required this.nowcast,
  });
  bool get hasFrames => past.isNotEmpty || nowcast.isNotEmpty;
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
    return RadarData(
      host: host,
      past: parse('past'),
      nowcast: parse('nowcast'),
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

/// Short label for a frame relative to now: "Hiện tại", "-20p", "+10p"…
String radarFrameLabel(RadarFrame f, {DateTime? now}) {
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final mins = (f.time - t) ~/ 60;
  if (mins.abs() < 5) return 'Hiện tại';
  return mins <= 0 ? '${mins.abs()}p' : '+${mins}p';
}
