/// Google Maps tiles as an OPT-IN basemap layer.
///
/// Google publishes no traffic tiles for third-party renderers, and its terms
/// forbid drawing Google *content* on a non-Google map — so this layer is the
/// whole Google map (tiles rendered by Google) rather than an overlay on the
/// OSM style. It is a layer choice, exactly like CARTO or ESRI: pick it in
/// "Lớp bản đồ" and the basemap becomes Google's roadmap; every other layer
/// (our route line, signs, cameras) is drawn on top as our own content.
///
/// ⚠ Unlike every other source in this app, these tiles are **never stored**:
/// the Map Tiles API terms allow a session-scoped render cache only, so
/// [OfflineTileImage] keeps them in the in-memory LRU and never touches the
/// disk cache. The layer is therefore online-only — offline it falls back to
/// the selected offline cache like any other online basemap.
///
/// COST (2026-10 pricing): the first 100,000 tile requests per month are free,
/// then $0.60 per 1,000; session-token requests are not billed. A 1 h drive
/// costs ~300–800 tiles, so normal use stays at $0 — see the billing note in
/// [hasKey].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GoogleTileConfig {
  /// Map Tiles API key, injected at build time:
  /// `--dart-define=GOOGLE_MAPS_API_KEY=...` (`tool/env.sh` fills it from the
  /// `GOOGLEMAPS_API_KEY` entry in `.env`).
  ///
  /// The project must have **Map Tiles API** enabled and billing active, and
  /// the key should be restricted (Android package + SHA-1 / HTTP referrer) —
  /// an unrestricted key with billing on is a bill waiting to happen.
  static const String apiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  /// True when the layer can be offered in the menu. Without a key its URLs
  /// would 403 on every tile, so the menu hides it (same rule as Vietmap).
  static bool get hasKey => apiKey.trim().isNotEmpty;

  /// How long a session token is reused before asking for a new one. Google
  /// hands out ~2-week tokens; we refresh well before that so a stale token
  /// cannot blank the map mid-drive, and immediately on a 403.
  static const Duration sessionTtl = Duration(hours: 12);

  static String? _session;
  static DateTime? _sessionAt;
  static Future<String?>? _inflight;

  /// The current session token, or null when it could not be created (no key,
  /// no network, API not enabled → the caller falls back to another basemap).
  static String? get session => _session;

  /// Tile URL for [session], or null when there is no session yet.
  ///
  /// The template is what both renderers consume: flutter_map expands
  /// `{z}/{x}/{y}` directly, and MapLibre understands the same placeholders.
  static String? tileUrl([String? token]) {
    final s = token ?? _session;
    if (!hasKey || s == null || s.isEmpty) return null;
    return 'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}'
        '?session=$s&key=$apiKey';
  }

  /// Create (or reuse) a session. Returns the token, or null on failure.
  ///
  /// `mapType: roadmap` is the standard basemap; `language: vi` + `region: VN`
  /// make Google label Vietnamese roads in Vietnamese, which is what the rest
  /// of the UI uses.
  static Future<String?> ensureSession({bool force = false}) {
    if (!hasKey) return Future.value(null);
    final at = _sessionAt;
    final fresh =
        at != null &&
        DateTime.now().difference(at) < sessionTtl &&
        (_session?.isNotEmpty ?? false);
    if (!force && fresh) return Future.value(_session);
    final running = _inflight;
    if (!force && running != null) return running;
    final f = _createSession();
    _inflight = f;
    return f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
  }

  static Future<String?> _createSession() async {
    try {
      final res = await http
          .post(
            Uri.parse(
              'https://tile.googleapis.com/v1/createSession'
              '?key=$apiKey',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object>{
              'mapType': 'roadmap',
              'language': 'vi',
              'region': 'VN',
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final doc = jsonDecode(res.body);
      final token = doc is Map ? doc['session'] as String? : null;
      if (token == null || token.isEmpty) return null;
      _session = token;
      _sessionAt = DateTime.now();
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Forget the token — the next [ensureSession] asks for a fresh one (a 403
  /// on a tile is the usual trigger: expired or revoked session).
  static void invalidateSession() {
    _session = null;
    _sessionAt = null;
  }

  /// Test seam: inject a token without network access.
  static void setSessionForTesting(String? token) {
    _session = token;
    _sessionAt = token == null ? null : DateTime.now();
  }
}
