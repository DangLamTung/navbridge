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
    final ctx = context?.toPrompt() ?? '';
    final userText = ctx.isEmpty ? question : '$question$ctx';
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
    final res = await http
        .post(
          Uri.parse(AiConfig.deepSeekEndpoint),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': AiConfig.deepSeekModel,
            'stream': true,
            'messages': [
              {'role': 'system', 'content': sys},
              for (final t in history)
                {'role': t.isUser ? 'user' : 'assistant', 'content': t.text},
              {'role': 'user', 'content': userText},
            ],
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('DeepSeek lỗi ${res.statusCode}: ${res.body}');
    }
    // SSE: "data: {...}\n\n" lines; accumulate deltas.
    final buffer = StringBuffer();
    final lines = const LineSplitter().convert(utf8.decode(res.bodyBytes));
    for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final delta = (j['choices'] as List? ?? const []);
        if (delta.isEmpty) continue;
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
    if (buffer.isEmpty) {
      throw Exception('DeepSeek không trả về nội dung.');
    }
    return AiReply(buffer.toString(), 'deepseek');
  }

  Future<AiReply> _askGemini(
    String key,
    String userText,
    List<ChatTurn> history,
    String sys,
    void Function(String)? onToken,
  ) async {
    final res = await http
        .post(
          Uri.parse('${AiConfig.geminiEndpoint}?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
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
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('Gemini lỗi ${res.statusCode}: ${res.body}');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final candidates = (j['candidates'] as List? ?? const []);
    if (candidates.isEmpty) throw Exception('Gemini không trả về nội dung.');
    final parts =
        (candidates.first as Map? ?? const {})['content']?['parts'] as List? ??
        const [];
    final text = parts
        .map((p) => (p as Map? ?? const {})['text'] as String? ?? '')
        .join();
    if (text.isEmpty) throw Exception('Gemini không trả về nội dung.');
    onToken?.call(text); // Gemini here is non-streamed — one token = full text
    return AiReply(text, 'gemini');
  }
}
