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
import 'package:http/http.dart' as http;

import 'package:navbridge/core/ai_config.dart';
import 'package:navbridge/core/ai_key_store.dart';
import 'package:navbridge/core/ai_memory.dart';
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/services/poi_search.dart';
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
  final String? tripNotes; // trip name / stop count

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
    this.tripNotes,
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
      if (nextManeuver != null) 'Lượt tiếp: $nextManeuver',
      ?cam,
      if (weather != null) 'Thời tiết: $weather',
      ?notes,
    ];
    return parts.isEmpty ? '' : '\n\nNgữ cảnh hiện tại: ${parts.join('; ')}.';
  }
}

/// One assistant reply (streamed tokens appended by [onToken]).
class AiReply {
  final String text;
  final String provider; // 'deepseek' | 'gemini'
  const AiReply(this.text, this.provider);
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
    var userText = ctx.isEmpty ? question : '$question$ctx';
    // REAL gas-station grounding: when the driver asks about fuel, run the
    // app's Overpass POI search and hand the actual stations (name + distance)
    // to the model so it NEVER invents coordinates (LLMs can't see a map).
    final center = context?.center;
    if (_isGasQuery(question) && center != null) {
      final gas = await _nearbyGasBlock(center);
      if (gas.isNotEmpty) userText = '$userText$gas';
    }
    final sys = await _systemPrompt();
    final trimmed = _trimHistory(history);

    // DeepSeek first (cheap + strong Vietnamese).
    if (deepSeekKey.isNotEmpty) {
      try {
        return await _askDeepSeek(deepSeekKey, userText, trimmed, sys, onToken);
      } catch (e) {
        debugPrint('AI: deepseek failed: $e — trying Gemini');
        if (geminiKey.isEmpty) rethrow;
      }
    }
    if (geminiKey.isNotEmpty) {
      return _askGemini(geminiKey, userText, trimmed, sys, onToken);
    }
    throw Exception(
      'Chưa cấu hình khoá AI. Vào ⚙ Cài đặt → Trợ lý AI để nhập khoá.',
    );
  }

  /// System prompt = base prompt + persistent driver facts (if any).
  Future<String> _systemPrompt() async {
    final mem = await AiMemory.instance.factsPrompt();
    return mem.isEmpty
        ? AiConfig.systemPrompt
        : '${AiConfig.systemPrompt}\n\n$mem';
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

  bool _isGasQuery(String q) => _gasRx.hasMatch(q);

  /// Query REAL nearby gas stations and format them as a Vietnamese block
  /// for the model. Prefers Google Places (better Vietnam coverage) via
  /// [googlePlaceTextSearch], falls back to Overpass [searchPois]. Empty
  /// string when none found.
  Future<String> _nearbyGasBlock(LatLng center) async {
    // 1) Google Places Text Search (best VN data when a key is configured).
    try {
      final g = await googlePlaceTextSearch(
        'trạm xăng',
        center,
        radius: 5000,
        limit: 6,
      );
      if (g.isNotEmpty) {
        debugPrint('AI: gas search → Google Places ${g.length} stations');
        return _formatStations(g, center, 'Google Maps');
      }
    } catch (e) {
      debugPrint('AI: Google gas search failed: $e');
    }
    // 2) Overpass amenity=fuel fallback.
    try {
      final pois = await searchPois(
        PoiType.fuel,
        center,
        radius: 5000,
        limit: 6,
      );
      if (pois.isEmpty) return '';
      debugPrint('AI: gas search → Overpass ${pois.length} stations');
      const Distance d = Distance();
      final lines = <String>[];
      for (final p in pois) {
        final m = d.as(LengthUnit.Meter, center, p.pos).round();
        lines.add('${p.name.isNotEmpty ? p.name : 'Trạm xăng'} (cách ~$m m)');
      }
      return '\n\nTrạm xăng gần đây (OSM thật — chỉ dùng danh sách này):\n- '
          '${lines.join('\n- ')}';
    } catch (e) {
      debugPrint('AI: gas search failed: $e');
      return '';
    }
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
