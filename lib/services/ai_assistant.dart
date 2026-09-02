/// AI assistant: answers the driver's questions using DeepSeek (primary)
/// or Google Gemini (fallback). Each call is grounded in the live drive
/// context (position, road, speed, destination, ETA, next maneuver,
/// camera-ahead, weather) so the answer is about the ACTUAL drive.
///
/// Keys come from the encrypted [AiKeyStore] first, then build-time defines.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'package:navbridge/core/ai_config.dart';
import 'package:navbridge/core/ai_key_store.dart';
import 'package:navbridge/core/ai_memory.dart';
import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/services/offline_tiles.dart' show isOnline;
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/services/poi_search.dart';
import 'package:navbridge/services/vietmap_api.dart';
import 'package:navbridge/services/vietmap_config.dart';
import 'package:latlong2/latlong.dart';

/// Everything the assistant knows about the current drive, injected into the
/// prompt so answers are grounded in reality.
class AiContext {
  final String? position; // "10.78, 106.65 (TP. HCM)"
  final String? road; // current road name / type
  final String? speedKmh;
  final String? destination;
  final String? eta; // "14:32"
  final String? nextManeuver; // "rẽ trái vào Lê Lợi trong 300 m"
  final String? cameraAhead; // "Camera tốc độ phía trước 500 m"
  final String? weather; // "30°C, mưa nhẹ"
  final String? radar; // rain prediction: "mưa 80% trong giờ tới"
  final String? tripNotes; // trip name / stop count

  /// Remaining distance to the destination ("Còn 45 km"); null when unknown.
  final String? routeRemainingKm;

  /// Count of enforcement/ahead cameras on the route within the next ~10 km.
  final int? camerasAhead;

  /// Count of mountain-pass ("đèo") road segments ahead on the route.
  final int? passesAhead;

  /// Distance to the nearest fuel station AHEAD on the route (km); null when
  /// none known. Lets the AI answer "trạm xăng còn xa không".
  final double? gasNextKm;

  /// Short description of difficult/hazardous sections AHEAD (e.g. "2 đoạn đèo,
  /// 12 km đường uốn gắt, 1 hầm") computed from route curvature + signs; null
  /// when the road ahead is easy.
  final String? hardSections;

  /// The car's position as coordinates (used for REAL POI lookups like
  /// nearby gas stations — not included in the visible prompt).
  final LatLng? center;

  const AiContext({
    this.position,
    this.road,
    this.speedKmh,
    this.destination,
    this.eta,
    this.nextManeuver,
    this.cameraAhead,
    this.weather,
    this.radar,
    this.tripNotes,
    this.routeRemainingKm,
    this.camerasAhead,
    this.passesAhead,
    this.gasNextKm,
    this.hardSections,
    this.center,
  });

  /// A compact Vietnamese block appended to the user question.
  String toPrompt() {
    final cam = cameraAhead;
    final notes = tripNotes;
    final parts = <String>[
      if (position != null) 'Vị trí: $position',
      if (road != null) 'Đường: $road',
      if (speedKmh != null) 'Tốc độ: $speedKmh',
      if (destination != null) 'Điểm đến: $destination',
      if (eta != null) 'ETA: $eta',
      if (routeRemainingKm != null) 'Còn lại: $routeRemainingKm',
      if (camerasAhead != null) 'Camera phía trước: $camerasAhead',
      if (passesAhead != null) 'Đèo phía trước: $passesAhead',
      if (gasNextKm != null)
        'Trạm xăng tiếp theo: ${gasNextKm!.toStringAsFixed(0)} km',
      if (hardSections != null) 'Đoạn khó đi phía trước: $hardSections',
      if (nextManeuver != null) 'Lượt tiếp: $nextManeuver',
      ?cam,
      if (weather != null) 'Thời tiết: $weather',
      if (radar != null) 'Mưa dự báo: $radar',
      ?notes,
    ];
    return parts.isEmpty ? '' : '\n\nNgữ cảnh hiện tại: ${parts.join('; ')}.';
  }
}

/// One assistant reply (streamed tokens appended by [onToken]).
class AiReply {
  final String text;
  final String provider; // 'deepseek' | 'gemini' | 'offline'
  final List<AiPlace> places; // real places the answer is grounded on
  final AiPlace? navigateTarget; // tool-call: driver wants to go here
  const AiReply(
    this.text,
    this.provider, {
    this.places = const [],
    this.navigateTarget,
  });
}

/// A real place the AI answer is grounded on (rendered as a "Đi đến" chip).
class AiPlace {
  final String name;
  final double lat;
  final double lng;
  const AiPlace(this.name, this.lat, this.lng);
}

/// A chat turn (user question or assistant reply) used for session memory.
/// Matches the record type the chat panel stores.
typedef ChatTurn = ({bool isUser, String text});

class AiAssistant {
  static final AiAssistant instance = AiAssistant._();
  AiAssistant._();

  /// Session memory caps — keep prompts cheap: last ~6 exchanges and at most
  /// ~6000 chars of history (oldest dropped first).
  static const int _maxHistoryMessages = 12;
  static const int _maxHistoryChars = 6000;

  /// Ask the assistant. [question] is the driver's text; [context] grounds it;
  /// [history] is the previous chat turns (session memory — trimmed to stay
  /// light). Persistent driver facts from [AiMemory] are injected into the
  /// system prompt. [onToken] receives partial text as it streams.
  /// Throws a descriptive exception on failure (caller shows a message).
  Future<AiReply> ask(
    String question, {
    AiContext? context,
    List<ChatTurn> history = const [],
    void Function(String partial)? onToken,
  }) async {
    final (sd, sg) = await AiKeyStore.instance.read();
    final deepSeekKey = (sd?.isNotEmpty ?? false)
        ? sd!
        : AiConfig.deepSeekApiKey;
    final geminiKey = (sg?.isNotEmpty ?? false) ? sg! : AiConfig.geminiApiKey;
    debugPrint(
      'AI: keys → deepseek=${deepSeekKey.isNotEmpty} '
      'gemini=${geminiKey.isNotEmpty} '
      '(store deepseek=${sd?.isNotEmpty ?? false} gemini=${sg?.isNotEmpty ?? false})',
    );
    final ctx = context?.toPrompt() ?? '';
    final center = context?.center;
    var userText = ctx.isEmpty ? question : '$question$ctx';

    // REAL grounding: run the app's POI search for fuel/food/cafe/hotel/ATM
    // and hand the actual places (name + distance) to the model so it NEVER
    // invents coordinates. The same places are returned as [AiReply.places]
    // so the chat can offer "Đi đến" buttons.
    final grounding = await _groundPlaces(question, center);
    if (grounding.$1.isNotEmpty) userText = '$userText${grounding.$1}';
    final places = grounding.$2;

    final sys = await _systemPrompt();
    final trimmed = _trimHistory(history);

    // Offline → answer from on-device data + live drive context (no network).
    if (!await isOnline()) {
      final off = await _offlineAnswer(question, context, center);
      if (off != null) return off;
    }
    // WEB grounding — HIGH priority: runs for almost every online question
    // (place queries too, so the answer can combine real places with current
    // web facts like ratings/news). Only pure nav-state / current-weather /
    // greeting questions skip it (answered from live drive context).
    if (_shouldWebSearch(question)) {
      final web = await _webSearch(question);
      if (web.isNotEmpty) userText = '$userText\n\n$web';
    }
    if (deepSeekKey.isEmpty && geminiKey.isEmpty) {
      throw Exception(
        'Chưa cấu hình khoá AI. Vào ⚙ Cài đặt → Trợ lý AI để nhập khoá.',
      );
    }

    // DeepSeek first (cheap + strong Vietnamese).
    if (deepSeekKey.isNotEmpty) {
      try {
        final r = await _askDeepSeek(
          deepSeekKey,
          userText,
          trimmed,
          sys,
          onToken,
        );
        final (txt, target) = _extractNavigate(r.text, places);
        return AiReply(txt, r.provider, places: places, navigateTarget: target);
      } catch (e) {
        debugPrint('AI: deepseek failed: $e — trying Gemini');
        if (geminiKey.isEmpty) rethrow;
      }
    }
    final g = await _askGemini(geminiKey, userText, trimmed, sys, onToken);
    final (txt, target) = _extractNavigate(g.text, places);
    return AiReply(txt, g.provider, places: places, navigateTarget: target);
  }

  /// System prompt = base prompt (from the repo asset, so it's easy to edit)
  /// + persistent driver facts (if any). Falls back to [AiConfig.systemPrompt]
  /// if the asset can't be loaded.
  Future<String> _systemPrompt() async {
    var base = AiConfig.systemPrompt;
    try {
      base = await rootBundle.loadString('assets/ai/system_prompt.txt');
    } catch (_) {}
    final mem = await AiMemory.instance.factsPrompt();
    return mem.isEmpty ? base : '$base\n\n$mem';
  }

  /// Keeps session memory light: at most the last [_maxHistoryMessages] turns
  /// and [_maxHistoryChars] chars, dropping the oldest first.
  List<ChatTurn> _trimHistory(List<ChatTurn> history) {
    if (history.isEmpty) return const [];
    final list = history.length <= _maxHistoryMessages
        ? history
        : history.sublist(history.length - _maxHistoryMessages);
    var total = 0;
    for (final t in list) {
      total += t.text.length;
    }
    var start = 0;
    while (total > _maxHistoryChars && start < list.length - 1) {
      total -= list[start].text.length;
      start++;
    }
    return start == 0 ? list : list.sublist(start);
  }

  /// Does [q] ask about fuel / gas stations?
  static final RegExp _gasRx = RegExp(
    r'(xăng|xang|trạm xăng|đổ xăng|gas|petrol|fuel)',
    caseSensitive: false,
  );

  /// Questions asking about beautiful places / mountain passes (đèo) / scenic
  /// stops along the drive → ground in real OSM viewpoints + đèo.
  static final RegExp _scenicRx = RegExp(
    r'(đẹp|dep|cảnh|canh|đèo|deo|ngắm|ngam|gợi ý|goi y|dọc đường|doc duong|điểm dừng|diem dung|phong cảnh|phong canh|thắng cảnh|thang canh)',
    caseSensitive: false,
  );

  bool _isGasQuery(String q) => _gasRx.hasMatch(q);

  /// Does [q] ask about the CURRENT PRICE of fuel ("giá xăng hôm nay bao
  /// nhiêu?") rather than finding a station? Price questions must go to the
  /// web-search pass (real current price) — NOT the nearby-station list, or
  /// the AI lists stations and can't (mustn't) give a price.
  static final RegExp _gasPriceRx = RegExp(
    r'(giá xăng|gia xang|xăng bao nhiêu|xang bao nhieu|xăng hôm nay|xang hom nay|xăng giá|xang gia|giá dầu|gia dau|dầu bao nhiêu|dau bao nhieu|ron 95 bao nhiêu|e5 bao nhiêu|giá ron|gia ron|1 lít xăng|1 lit xang|giá xăng dầu|gia xang dau)',
    caseSensitive: false,
  );

  bool _isGasPriceQuery(String q) => _gasPriceRx.hasMatch(q.toLowerCase());

  /// Real nearby gas stations → prompt block + places. Google Places first
  /// (best VN data), Overpass fallback.
  Future<(String, List<AiPlace>)> _groundGas(LatLng center) async {
    try {
      final g = await googlePlaceTextSearch(
        'trạm xăng',
        center,
        radius: 5000,
        limit: 6,
      );
      if (g.isNotEmpty) {
        debugPrint('AI: gas search → Google Places ${g.length} stations');
        return (
          _formatStations(g, center, 'Google Maps'),
          [for (final (n, la, ln) in g) AiPlace(n, la, ln)],
        );
      }
    } catch (e) {
      debugPrint('AI: Google gas search failed: $e');
    }
    try {
      final pois = await searchPois(
        PoiType.fuel,
        center,
        radius: 5000,
        limit: 6,
      );
      if (pois.isEmpty) return ('', const <AiPlace>[]);
      debugPrint('AI: gas search → Overpass ${pois.length} stations');
      const Distance d = Distance();
      final lines = <String>[];
      for (final p in pois) {
        final m = d.as(LengthUnit.Meter, center, p.pos).round();
        lines.add('${p.name.isNotEmpty ? p.name : 'Trạm xăng'} (cách ~$m m)');
      }
      return (
        '\n\nTrạm xăng gần đây (OSM thật — chỉ dùng danh sách này):\n- '
            '${lines.join('\n- ')}',
        [for (final p in pois) AiPlace(p.name, p.lat, p.lng)],
      );
    } catch (e) {
      debugPrint('AI: gas search failed: $e');
      return ('', const <AiPlace>[]);
    }
  }

  /// Run the app's REAL POI search for the intent of [q] (fuel / food / café /
  /// hotel / ATM), returning a Vietnamese block for the model AND the places
  /// for "Đi đến" chips. Empty when no matching intent or no location.
  Future<(String, List<AiPlace>)> _groundPlaces(
    String q,
    LatLng? center,
  ) async {
    if (center == null) return ('', const <AiPlace>[]);
    final lower = q.toLowerCase();
    // "Giá xăng hôm nay …" = a PRICE question, not "find a station" — return
    // empty so the web-search pass (in ask()) supplies the latest price; the
    // station list would only tempt the model to list stations with no price.
    if (_isGasPriceQuery(lower)) return ('', const <AiPlace>[]);
    if (_isGasQuery(lower)) return _groundGas(center);
    final type = _poiTypeForQuery(lower);
    // "Đẹp / đèo / ngắm cảnh / gợi ý dọc đường" → real scenic spots + mountain
    // passes (đèo) via Overpass, so the AI suggests REAL beautiful places
    // (with coordinates for the "Đi đến" chips) — not invented ones.
    if (type == null && _scenicRx.hasMatch(q)) {
      try {
        final spots = await searchScenicSpots(center, radius: 20000, limit: 8);
        if (spots.isNotEmpty) {
          const Distance d = Distance();
          final lines = <String>[];
          for (final s in spots) {
            final m = d
                .as(LengthUnit.Meter, center, LatLng(s.lat, s.lng))
                .round();
            lines.add('${s.name} (${s.kind}, cách ~$m m)');
          }
          return (
            '\n\nĐiểm đẹp/đèo thật gần đây (OSM — chỉ dùng danh sách này, '
                'kèm khoảng cách):\n- ${lines.join('\n- ')}',
            [for (final s in spots) AiPlace(s.name, s.lat, s.lng)],
          );
        }
      } catch (e) {
        debugPrint('AI: scenic search failed: $e');
      }
    }
    if (type == null) {
      // Named-place query ("tìm quán phở X", "khách sạn Vinpearl ở đâu") —
      // the driver names a SPECIFIC place → ground in a real place search
      // (Google Places Text Search first, Vietmap fallback).
      if (_isNamedPlaceQuery(lower)) {
        return _groundNamedPlace(lower, center);
      }
      return ('', const <AiPlace>[]);
    }
    try {
      final pois = await searchPois(type, center, radius: 8000, limit: 5);
      if (pois.isEmpty) return ('', const <AiPlace>[]);
      const Distance d = Distance();
      final lines = <String>[];
      for (final p in pois) {
        final m = d.as(LengthUnit.Meter, center, p.pos).round();
        lines.add('${p.name.isNotEmpty ? p.name : type.label} (cách ~$m m)');
      }
      final block =
          '\n\n$type.label gần đây (OSM thật — chỉ dùng danh sách này, kèm '
          'khoảng cách):\n- ${lines.join('\n- ')}';
      return (block, [for (final p in pois) AiPlace(p.name, p.lat, p.lng)]);
    } catch (e) {
      debugPrint('AI: $type search failed: $e');
      return ('', const <AiPlace>[]);
    }
  }

  /// Map a question to a POI category (fuel handled separately in [_isGasQuery]).
  PoiType? _poiTypeForQuery(String lower) {
    if (lower.contains('võng') || lower.contains('vong')) {
      return PoiType.cafeVong;
    }
    if (lower.contains('cà phê') ||
        lower.contains('ca phe') ||
        lower.contains('coffee')) {
      return PoiType.food;
    }
    if (lower.contains('nhà hàng') ||
        lower.contains('nha hang') ||
        lower.contains('quán ăn') ||
        lower.contains('quan an') ||
        lower.contains('ăn uống') ||
        lower.contains('an uong') ||
        lower.contains('restaurant') ||
        lower.contains('food')) {
      return PoiType.food;
    }
    if (lower.contains('khách sạn') ||
        lower.contains('khach san') ||
        lower.contains('hotel') ||
        lower.contains('motel') ||
        lower.contains('nhà nghỉ') ||
        lower.contains('nha nghi')) {
      return PoiType.hotel;
    }
    if (lower.contains('atm') ||
        lower.contains('ngân hàng') ||
        lower.contains('ngan hang') ||
        lower.contains('bank') ||
        lower.contains('rút tiền') ||
        lower.contains('rut tien')) {
      return PoiType.atm;
    }
    if (lower.contains('bệnh viện') ||
        lower.contains('benh vien') ||
        lower.contains('nhà thuốc') ||
        lower.contains('nha thuoc') ||
        lower.contains('hiệu thuốc') ||
        lower.contains('pharmacy') ||
        lower.contains('hospital') ||
        lower.contains('y tế') ||
        lower.contains('y te')) {
      return PoiType.hospital;
    }
    return null;
  }

  /// Does [q] ask to find a SPECIFIC place by name (not a category the
  /// category-POI search already handles)? e.g. "tìm quán phở Hùng",
  /// "khách sạn Vinpearl ở đâu", "siêu thị gần đây".
  static final RegExp _placeIntentRx = RegExp(
    r'(tìm|kiếm|tim|kiem|ở đâu|o dau|chỗ nào|cho nao|quanh đây|quanh day|gần đây|gan day|địa điểm|dia diem|chỗ|cho|quán|quan|tiệm|tiem|cửa hàng|cua hang|siêu thị|sieu thi|chợ|cho|trạm|tram|bãi|bai|sân bay|san bay|công viên|cong vien|điểm dừng|diem dung|khách sạn|khach san|nhà nghỉ|nha nghi|bến xe|ben xe)',
    caseSensitive: false,
  );

  bool _isNamedPlaceQuery(String q) => _placeIntentRx.hasMatch(q);

  /// Strip the search intent words off a place query so the engine searches
  /// just the place name: "tìm quán phở Hùng gần đây" → "quán phở Hùng".
  String _cleanPlaceQuery(String q) {
    var s = q.trim();
    final lead = RegExp(
      r'^(tìm kiếm|tìm|kiếm|cho tôi|giúp tôi|hãy|chỉ|đi tìm|đưa tôi|cho mình|mình muốn)\s+',
      caseSensitive: false,
    );
    // Strip a chain of leading intent words ("giúp tôi tìm …").
    var prev = '';
    while (s != prev) {
      prev = s;
      s = s.replaceFirst(lead, '');
    }
    s = s.replaceFirst(
      RegExp(
        r'\s*(gần đây|gần nhất|ở đâu|quanh đây|chỗ nào|chỗ|tại)\s*[?!.]*$',
        caseSensitive: false,
      ),
      '',
    );
    return s.trim();
  }

  /// Real NAMED-place search (Google Places Text Search first — best VN data
  /// with real coordinates — then Vietmap autocomplete + place lookup).
  /// Returns a prompt block + places for the "Đi đến" chips.
  Future<(String, List<AiPlace>)> _groundNamedPlace(
    String q,
    LatLng center,
  ) async {
    final clean = _cleanPlaceQuery(q);
    if (clean.isEmpty) return ('', const <AiPlace>[]);
    const Distance d = Distance();
    // 1) Google Places Text Search — real names + coordinates.
    try {
      final g = await googlePlaceTextSearch(
        clean,
        center,
        radius: 20000,
        limit: 5,
      );
      if (g.isNotEmpty) {
        final lines = <String>[];
        final places = <AiPlace>[];
        for (final (n, la, ln) in g) {
          final m = d.as(LengthUnit.Meter, center, LatLng(la, ln)).round();
          lines.add('$n (cách ~$m m)');
          places.add(AiPlace(n, la, ln));
        }
        debugPrint('AI: place search → Google ${g.length} results');
        return (
          '\n\nKết quả tìm "$clean" (Google Maps thật — chỉ dùng danh sách này, kèm khoảng cách):\n- ${lines.join('\n- ')}',
          places,
        );
      }
    } catch (e) {
      debugPrint('AI: Google place search failed: $e');
    }
    // 2) Vietmap autocomplete + place (coords) when the key is present.
    if (VietmapConfig.hasKeys) {
      try {
        final vm = await vietmapAutocomplete(clean, focus: center);
        final places = <AiPlace>[];
        final lines = <String>[];
        for (final s in vm.take(3)) {
          final p = await vietmapPlace(s.refId);
          if (p == null) continue;
          final (la, ln, _) = p;
          final m = d.as(LengthUnit.Meter, center, LatLng(la, ln)).round();
          lines.add('${s.display} (cách ~$m m)');
          places.add(AiPlace(s.display, la, ln));
        }
        if (places.isNotEmpty) {
          debugPrint('AI: place search → Vietmap ${places.length} results');
          return (
            '\n\nKết quả tìm "$clean" (Vietmap thật — chỉ dùng danh sách này, kèm khoảng cách):\n- ${lines.join('\n- ')}',
            places,
          );
        }
      } catch (e) {
        debugPrint('AI: Vietmap place search failed: $e');
      }
    }
    return ('', const <AiPlace>[]);
  }

  /// Drive-context / greeting questions are already answered from the live
  /// drive context — don't burn a web search on them. (Traffic / speed-limit /
  /// đèo / route questions DO get web, so e.g. "cao tốc nào đang kẹt" can
  /// pull current info.)
  static final RegExp _driveCtxRx = RegExp(
    r'(bao lâu|mấy phút|mấy km|còn xa|eta|đến nơi|tới nơi|rẽ|lượt|tiếp theo|chạy tiếp|camera|thời tiết|mưa|hướng đi|trạm dừng|chỗ đỗ|đỗ xe)',
    caseSensitive: false,
  );
  static final RegExp _greetingRx = RegExp(
    r'^(chào|hello|hi|hey|alo|ờ|ok|vâng)\b',
    caseSensitive: false,
  );

  bool _shouldWebSearch(String q) {
    if (_greetingRx.hasMatch(q)) return false;
    if (_driveCtxRx.hasMatch(q)) return false;
    return true;
  }

  /// Keyless real web grounding for factual questions. All sources run in
  /// PARALLEL and the first non-empty wins, so latency stays low even though
  /// DuckDuckGo / Wikipedia can be slow. Returns a compact block the model
  /// must base its answer on (never invented numbers/news).
  Future<String> _webSearch(String q) async {
    final query = _cleanWebQuery(q);
    final futures = <Future<String>>[
      _ddgInstantAnswer(query),
      _ddgHtmlSnippets(query),
      _wikipediaIntro(query),
    ];
    // Tavily (when a key is configured) is the PRIMARY source — clean JSON
    // built for AI grounding; the free DDG / Wikipedia sources back it up.
    if (AiConfig.tavilyApiKey.isNotEmpty) {
      futures.insert(0, _tavilySearch(query));
    }
    final results = await Future.wait(futures);
    debugPrint(
      'AI: web "$query" → ${results.map((r) => r.length).join('/')} chars',
    );
    for (final r in results) {
      if (r.isNotEmpty) return r;
    }
    return '';
  }

  /// Tavily Search API (real-time, AI-optimized): POST /search with the key
  /// from AiConfig. Returns a compact Vietnamese web block (the model must
  /// base its answer on it), or '' when no key / on any failure. Tavily is
  /// used FIRST when configured because it returns clean snippets + a direct
  /// answer instead of scraped HTML.
  Future<String> _tavilySearch(String query) async {
    final key = AiConfig.tavilyApiKey;
    if (key.isEmpty) return '';
    try {
      final res = await http
          .post(
            Uri.parse('https://api.tavily.com/search'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'query': query,
              'max_results': 5,
              'search_depth': 'basic',
              'include_answer': true,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        debugPrint('AI: tavily HTTP ${res.statusCode}: ${res.body}');
        return '';
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final answer = (data['answer'] as String?)?.trim() ?? '';
      final results = (data['results'] as List?) ?? const [];
      final lines = <String>[];
      if (answer.isNotEmpty) lines.add(answer);
      for (final r in results.take(5)) {
        if (r is Map) {
          final title = (r['title'] as String?)?.trim() ?? '';
          final content = (r['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) {
            final t = title.isEmpty ? '' : '$title: ';
            final c = content.length > 400
                ? '${content.substring(0, 400)}…'
                : content;
            lines.add('$t$c');
          }
        }
      }
      debugPrint(
        'AI: tavily results=${results.length} ans=${answer.length} '
        'lines=${lines.length}',
      );
      if (lines.isNotEmpty) {
        return 'Thông tin web (Tavily):\n- ${lines.take(5).join('\n- ')}';
      }
    } catch (e) {
      debugPrint('AI: tavily failed: $e');
    }
    return '';
  }

  /// DuckDuckGo Instant Answer API (structured abstract + related topics).
  Future<String> _ddgInstantAnswer(String query) async {
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://api.duckduckgo.com/?q=${Uri.encodeQueryComponent(query)}'
              '&format=json&no_html=1&skip_disambig=1&kl=vi-vn',
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('AI: ddg-ia HTTP ${res.statusCode}');
        return '';
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final heading = (data['Heading'] as String?)?.trim() ?? '';
      final lines = <String>[];
      final abs = (data['AbstractText'] as String?)?.trim();
      if (abs != null && abs.isNotEmpty) lines.add(abs);
      for (final rt in ((data['RelatedTopics'] as List?) ?? const [])) {
        if (lines.length >= 5) break;
        if (rt is Map) {
          final t = (rt['Text'] as String?)?.trim();
          if (t != null && t.isNotEmpty && lines.length < 5) lines.add(t);
          for (final tp in ((rt['Topics'] as List?) ?? const [])) {
            if (tp is Map && lines.length < 5) {
              final t2 = (tp['Text'] as String?)?.trim();
              if (t2 != null && t2.isNotEmpty) lines.add(t2);
            }
          }
        }
      }
      if (lines.isNotEmpty) {
        return 'Thông tin web (DuckDuckGo${heading.isNotEmpty ? ' — $heading' : ''}):\n- ${lines.take(5).join('\n- ')}';
      }
    } catch (_) {}
    return '';
  }

  /// DuckDuckGo HTML lite — real result snippets (best for current facts like
  /// giá xăng hôm nay). Uses a REAL mobile browser UA so DDG doesn't serve an
  /// anti-bot page to the generic "navbridge" UA.
  Future<String> _ddgHtmlSnippets(String query) async {
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}',
            ),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13; itel-P663LN) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0 Mobile Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('AI: ddg-html HTTP ${res.statusCode}');
        return '';
      }
      final results = <String>[];
      final re = RegExp(
        r'class="result__snippet"[^>]*>(.*?)</a>',
        dotAll: true,
      );
      for (final m in re.allMatches(res.body)) {
        final s = _stripHtml(m.group(1) ?? '');
        if (s.isNotEmpty) results.add(s);
        if (results.length >= 4) break;
      }
      debugPrint(
        'AI: ddg-html body=${res.body.length} snippets=${results.length}',
      );
      if (results.isNotEmpty) {
        return 'Thông tin web (DuckDuckGo):\n- ${results.take(4).join('\n- ')}';
      }
    } catch (_) {}
    return '';
  }

  /// Wikipedia (tiếng Việt) — khái niệm / sự kiện / địa danh.
  Future<String> _wikipediaIntro(String query) async {
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://vi.wikipedia.org/w/api.php?action=query&format=json'
              '&prop=extracts&exintro=1&explaintext=1&redirects=1'
              '&generator=search&gsrsearch=${Uri.encodeQueryComponent(query)}'
              '&gsrlimit=1&gsrnamespace=0',
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('AI: wikipedia HTTP ${res.statusCode}');
        return '';
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final pages = ((data['query'] as Map?)?['pages'] as Map?) ?? const {};
      for (final p in pages.values) {
        if (p is Map) {
          final ex = (p['extract'] as String?)?.trim();
          final title = (p['title'] as String?)?.trim() ?? '';
          if (ex != null && ex.isNotEmpty) {
            final text = ex.length > 900 ? '${ex.substring(0, 900)}…' : ex;
            return 'Wikipedia — $title:\n$text';
          }
        }
      }
      debugPrint('AI: wikipedia no extract');
    } catch (_) {}
    return '';
  }

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&nbsp;', ' ')
      .trim();

  /// Drop question fillers that hurt search-engine matching ("giá xăng hôm
  /// nay bao nhiêu?" → "giá xăng hôm nay").
  String _cleanWebQuery(String q) {
    var s = q.trim();
    s = s.replaceAll(RegExp(r'[?!.]+$'), '');
    s = s.replaceFirst(
      RegExp(r'\s*(bao nhiêu|bao nhieu|bấy nhiêu)\s*$', caseSensitive: false),
      '',
    );
    return s.trim();
  }

  /// Parse the AI's tool-call marker `[ĐI ĐẾN: Tên]` off the reply: returns
  /// the cleaned text and the resolved place (matched against the REAL
  /// grounded [places] — never trusts AI coordinates). Null target when the
  /// name can't be matched to a real place (the marker is just removed).
  (String, AiPlace?) _extractNavigate(String text, List<AiPlace> places) {
    final m = RegExp(
      r'\[ĐI ĐẾN:\s*([^\]]+)\]',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return (text, null);
    final name = m.group(1)!.trim();
    final clean = text.replaceRange(m.start, m.end, '').trim();
    final want = _stripDiacritics(name).toLowerCase();
    if (want.isEmpty) return (clean, null);
    for (final p in places) {
      final pn = _stripDiacritics(p.name).toLowerCase();
      if (pn.contains(want) || want.contains(pn)) return (clean, p);
    }
    return (clean, null);
  }

  static String _stripDiacritics(String s) {
    const vi =
        'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ';
    const en =
        'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuuyyyyyd';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = vi.indexOf(ch);
      b.write(i >= 0 ? en[i] : ch);
    }
    return b.toString();
  }

  /// Rule-based OFFLINE answers (no network): uses the on-device POI DB and
  /// the live drive context. Always returns a message (never hangs).
  Future<AiReply?> _offlineAnswer(
    String q,
    AiContext? context,
    LatLng? center,
  ) async {
    final lower = q.toLowerCase();
    if (_isGasQuery(lower) && center != null) {
      try {
        final pois = await poisInCategory('fuel', near: center, limit: 5);
        if (pois.isNotEmpty) {
          const Distance d = Distance();
          final lines = <String>[];
          for (final p in pois) {
            final m = d.as(LengthUnit.Meter, p.pos, center).round();
            lines.add('${p.name} (cách ~$m m)');
          }
          final ps = [for (final p in pois) AiPlace(p.name, p.lat, p.lng)];
          return AiReply(
            'Đang ngoại tuyến — trạm xăng gần đây (dữ liệu lưu trên máy):\n'
                '${lines.join('\n')}',
            'offline',
            places: ps,
            navigateTarget: ps.isEmpty ? null : ps.first,
          );
        }
      } catch (e) {
        debugPrint('AI: offline gas failed: $e');
      }
    }
    if (lower.contains('bao lâu') ||
        lower.contains('mấy phút') ||
        lower.contains('eta')) {
      final eta = context?.eta;
      final dest = context?.destination;
      if (eta != null) {
        return AiReply(
          'Đến ${dest ?? 'điểm đến'} khoảng $eta (ngoại tuyến).',
          'offline',
        );
      }
    }
    if (lower.contains('thời tiết') ||
        lower.contains('mưa') ||
        lower.contains('trời') ||
        lower.contains('nóng')) {
      final w = context?.weather;
      if (w != null) {
        return AiReply('Thời tiết hiện tại: $w (ngoại tuyến).', 'offline');
      }
      return const AiReply(
        'Đang ngoại tuyến, chưa lấy được thời tiết.',
        'offline',
      );
    }
    if (lower.contains('xin chào') ||
        lower.contains('hello') ||
        lower.trim() == 'hi' ||
        lower.contains('giúp') ||
        lower.contains('làm gì')) {
      return const AiReply(
        'Chào bạn! Tôi là trợ lý NavBridge. Đang ngoại tuyến nên tôi trả lời '
            'được một số câu như: "trạm xăng gần nhất", "thời tiết", "bao lâu '
            'tới nơi". Có mạng để hỏi đầy đủ hơn.',
        'offline',
      );
    }
    return const AiReply(
      'Hiện không có kết nối mạng nên trợ lý AI đang tạm tắt. '
          'Tôi vẫn trả lời được: trạm xăng, thời tiết, thời gian đến.',
      'offline',
    );
  }

  String _formatStations(
    List<(String, double, double)> stations,
    LatLng center,
    String source,
  ) {
    const Distance d = Distance();
    final lines = <String>[];
    for (final (name, lat, lng) in stations) {
      final m = d.as(LengthUnit.Meter, center, LatLng(lat, lng)).round();
      lines.add('$name (cách ~$m m)');
    }
    return '\n\nTrạm xăng gần đây ($source thật — chỉ dùng danh sách này):\n- '
        '${lines.join('\n- ')}';
  }

  @visibleForTesting
  List<ChatTurn> trimHistoryForTest(List<ChatTurn> history) =>
      _trimHistory(history);

  @visibleForTesting
  String cleanPlaceQueryForTest(String q) => _cleanPlaceQuery(q);

  @visibleForTesting
  bool isNamedPlaceQueryForTest(String q) => _isNamedPlaceQuery(q);

  @visibleForTesting
  bool isGasPriceQueryForTest(String q) => _isGasPriceQuery(q);

  @visibleForTesting
  String cleanWebQueryForTest(String q) => _cleanWebQuery(q);

  @visibleForTesting
  bool shouldWebSearchForTest(String q) => _shouldWebSearch(q);

  Future<AiReply> _askDeepSeek(
    String key,
    String userText,
    List<ChatTurn> history,
    String sys,
    void Function(String)? onToken,
  ) async {
    final request = http.Request('POST', Uri.parse(AiConfig.deepSeekEndpoint))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $key'
      ..body = jsonEncode({
        'model': AiConfig.deepSeekModel,
        'stream': true,
        'messages': [
          {'role': 'system', 'content': sys},
          for (final t in history)
            {'role': t.isUser ? 'user' : 'assistant', 'content': t.text},
          {'role': 'user', 'content': userText},
        ],
      });
    final client = http.Client();
    try {
      final res = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        final errBody = await res.stream.bytesToString();
        throw Exception('DeepSeek lỗi ${res.statusCode}: $errBody');
      }
      // SSE: "data: {...}\n\n" lines, read incrementally so tokens stream.
      final buffer = StringBuffer();
      final lineBuf = StringBuffer();
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        lineBuf.write(chunk);
        var s = lineBuf.toString();
        var nl = s.indexOf('\n');
        while (nl != -1) {
          _consumeDeepSeekLine(s.substring(0, nl), buffer, onToken);
          s = s.substring(nl + 1);
          nl = s.indexOf('\n');
        }
        lineBuf
          ..clear()
          ..write(s);
      }
      if (lineBuf.isNotEmpty) {
        _consumeDeepSeekLine(lineBuf.toString(), buffer, onToken);
      }
      if (buffer.isEmpty) {
        throw Exception('DeepSeek không trả về nội dung.');
      }
      return AiReply(buffer.toString(), 'deepseek');
    } on TimeoutException {
      throw Exception('DeepSeek hết thời gian chờ (60s). Thử lại.');
    } finally {
      client.close();
    }
  }

  /// Parse one SSE "data: …" line from DeepSeek and stream any content token.
  void _consumeDeepSeekLine(
    String line,
    StringBuffer buffer,
    void Function(String)? onToken,
  ) {
    if (!line.startsWith('data:')) return;
    final payload = line.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') return;
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final delta = (j['choices'] as List? ?? const []);
      if (delta.isEmpty) return;
      final c = (delta.first as Map? ?? const {})['delta'] as Map?;
      final piece = c?['content'] as String? ?? '';
      if (piece.isNotEmpty) {
        buffer.write(piece);
        onToken?.call(piece);
      }
    } catch (_) {
      // skip malformed SSE frames
    }
  }

  Future<AiReply> _askGemini(
    String key,
    String userText,
    List<ChatTurn> history,
    String sys,
    void Function(String)? onToken,
  ) async {
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': sys},
        ],
      },
      'contents': [
        for (final t in history)
          {
            'role': t.isUser ? 'user' : 'model',
            'parts': [
              {'text': t.text},
            ],
          },
        {
          'role': 'user',
          'parts': [
            {'text': userText},
          ],
        },
      ],
      'generationConfig': {'temperature': 0.6},
    });

    // Try newer models first, falling back when a model id is unavailable for
    // this key (404 / "not found") OR overloaded (5xx / 429 — a just-launched
    // model like 3.7-flash is often briefly overloaded). Uses
    // streamGenerateContent?alt=sse so tokens stream into the UI live.
    var lastSc = 503;
    var lastBody = '{"error":{"message":"model overloaded"}}';
    for (final model in AiConfig.geminiModels) {
      final uri = Uri.parse(
        '${AiConfig.geminiEndpointFor(model)}?alt=sse&key=$key',
      );
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..body = body;
      final client = http.Client();
      http.StreamedResponse streamed;
      try {
        streamed = await client
            .send(request)
            .timeout(const Duration(seconds: 60));
      } on TimeoutException {
        client.close();
        throw Exception(
          'Gemini hết thời gian chờ (60s). Thử lại hoặc dùng DeepSeek.',
        );
      }
      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        client.close();
        lastSc = streamed.statusCode;
        lastBody = errBody;
        debugPrint(
          'AI: GEMINI HTTP ${streamed.statusCode} model=$model body=$errBody',
        );
        final sc = streamed.statusCode;
        final fallback =
            sc == 404 ||
            sc >= 500 ||
            sc == 429 ||
            errBody.toLowerCase().contains('not found');
        if (fallback) continue; // try the next model id down the chain
        throw Exception(_friendlyGeminiError(sc, errBody));
      }

      final buffer = StringBuffer();
      final lineBuf = StringBuffer();
      try {
        await for (final chunk in streamed.stream.transform(utf8.decoder)) {
          lineBuf.write(chunk);
          var s = lineBuf.toString();
          var nl = s.indexOf('\n');
          while (nl != -1) {
            _consumeGeminiLine(s.substring(0, nl), buffer, onToken);
            s = s.substring(nl + 1);
            nl = s.indexOf('\n');
          }
          lineBuf
            ..clear()
            ..write(s);
        }
        if (lineBuf.isNotEmpty) {
          _consumeGeminiLine(lineBuf.toString(), buffer, onToken);
        }
      } finally {
        client.close();
      }
      if (buffer.isEmpty) {
        throw Exception('Gemini không trả về nội dung.');
      }
      return AiReply(buffer.toString(), 'gemini');
    }
    throw Exception(_friendlyGeminiError(lastSc, lastBody));
  }

  /// Parse one SSE "data: …" line from Gemini and stream any text token out.
  void _consumeGeminiLine(
    String line,
    StringBuffer buffer,
    void Function(String)? onToken,
  ) {
    if (!line.startsWith('data:')) return;
    final payload = line.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') return;
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final cands = (j['candidates'] as List? ?? const []);
      if (cands.isEmpty) return;
      final parts =
          (cands.first as Map? ?? const {})['content']?['parts'] as List? ??
          const [];
      for (final p in parts) {
        final piece = (p as Map? ?? const {})['text'] as String? ?? '';
        if (piece.isNotEmpty) {
          buffer.write(piece);
          onToken?.call(piece);
        }
      }
    } catch (_) {
      // Skip malformed SSE frames.
    }
  }

  /// Translate a Gemini API failure into a driver-friendly Vietnamese message
  /// (key invalid / API not enabled / region-blocked / model / quota), so the
  /// user knows WHAT to fix instead of a raw JSON dump.
  String _friendlyGeminiError(int status, String body) {
    String msg = '';
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      msg = ((j['error'] as Map? ?? const {})['message'] ?? '') as String;
    } catch (_) {}
    final lower = msg.toLowerCase();
    if (lower.contains('api key not valid') ||
        lower.contains('api key expired') ||
        lower.contains('invalid api key')) {
      return 'Gemini lỗi: khoá API không hợp lệ hoặc đã hết hạn. Vào ⚙ Cài đặt '
          '→ Trợ lý AI → kiểm tra lại khoá Gemini (tạo mới tại '
          'aistudio.google.com/apikey).';
    }
    if (lower.contains('unsupported country') ||
        lower.contains('region') ||
        lower.contains('territory')) {
      return 'Gemini lỗi: Google không hỗ trợ Gemini API ở quốc gia/khu vực này '
          '(thường chặn Việt Nam). Nên dùng DeepSeek (mặc định) hoặc đăng nhập '
          'bằng tài khoản Google ở khu vực được hỗ trợ.';
    }
    if (lower.contains('not found')) {
      return 'Gemini lỗi: mô hình ${AiConfig.geminiModel} không có sẵn cho khoá '
          'này (kiểm tra quyền truy cập mô hình của khoá).';
    }
    if (lower.contains('api has not been used') ||
        lower.contains('not been enabled') ||
        lower.contains('permission')) {
      return 'Gemini lỗi: chưa bật "Generative Language API" cho project của '
          'khoá này (Google Cloud Console → APIs & Services → bật Generative '
          'Language API).';
    }
    if (status == 429 ||
        lower.contains('quota') ||
        lower.contains('rate limit')) {
      return 'Gemini lỗi: vượt quota / giới hạn tốc độ. Thử lại sau hoặc dùng '
          'DeepSeek.';
    }
    return 'Gemini lỗi $status: ${msg.isEmpty ? body : msg}';
  }
}
