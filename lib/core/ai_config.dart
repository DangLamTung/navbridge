/// AI assistant configuration (DeepSeek + Gemini API keys + endpoints).
///
/// The REAL keys live ENCRYPTED on-device in `flutter_secure_storage`
/// (Android Keystore / iOS Keychain) — see [AiKeyStore]. The build-time
/// defines below are only a dev convenience / fallback (same pattern as
/// Vietmap): `--dart-define=DEEPSEEK_API_KEY=...` etc. They are never the
/// primary source and are NOT written to git.
library;

import 'package:navbridge/core/ai_key_store.dart' show AiKeyStore;

class AiConfig {
  /// DeepSeek API key — build-time dev fallback (encrypted runtime key wins).
  static const String deepSeekApiKey = String.fromEnvironment(
    'DEEPSEEK_API_KEY',
  );

  /// Google Gemini API key — build-time dev fallback.
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Tavily web-search API key — real-time, AI-optimized web grounding for
  /// the assistant. Build-time only (`--dart-define=TAVILY_API_KEY=...`, from
  /// `.env` via tool/env.sh). Empty = the AI falls back to the free
  /// DuckDuckGo / Wikipedia sources.
  static const String tavilyApiKey = String.fromEnvironment('TAVILY_API_KEY');

  /// DeepSeek chat endpoint (OpenAI-compatible chat completions).
  static const String deepSeekEndpoint =
      'https://api.deepseek.com/chat/completions';

  /// DeepSeek model — cheap, strong Vietnamese.
  static const String deepSeekModel = 'deepseek-chat';

  /// Gemini endpoint builder (v1beta generative). The `key` is the API key.
  static String geminiEndpointFor(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

  /// Primary Gemini endpoint (matches [geminiModel]).
  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-3.7-flash:generateContent';

  /// Gemini model ids tried in order — the assistant falls back to the next
  /// one when a model id is "not found" for the key. gemini-2.0-flash was
  /// RETIRED by Google (late 2025); the fast line is now 3.7-flash, with
  /// older ids kept as safe fallbacks for keys without access to it.
  static const List<String> geminiModels = [
    'gemini-3.7-flash',
    'gemini-3.5-flash',
    'gemini-3.0-flash',
    'gemini-2.5-flash',
  ];

  /// Primary Gemini model id.
  static const String geminiModel = 'gemini-3.7-flash';

  /// Default system prompt — a Vietnamese navigation assistant grounded in
  /// the live drive context (position, route, ETA, camera ahead, …).
  static const String systemPrompt =
      'Bạn là trợ lý dẫn đường NavBridge trên điện thoại. Trả lời ngắn gọn '
      'bằng tiếng Việt, thân thiện, tập trung vào việc giúp tài xế: '
      'giải thích lộ trình, ước lượng thời gian, tìm trạm xăng/nhà hàng/'
      'cà phê võng gần tuyến đường, cảnh báo camera, thời tiết, mẹo lái xe. '
      'Khi tài xế hỏi tìm trạm xăng: CHỈ dùng danh sách "Trạm xăng gần đây" '
      'được cung cấp trong câu hỏi (kèm khoảng cách), đừng bịa tên hoặc tọa '
      'độ; nếu không có danh sách thì nói chưa tìm thấy trạm xăng gần đây. '
      'Nếu câu hỏi cần vị trí cụ thể mà ngữ cảnh không có, hãy hỏi lại. '
      'Không bịa thông tin; nếu không biết thì nói không chắc.';

  /// True when at least one usable key is available (secure storage or the
  /// build-time define).
  static Future<bool> get hasAnyKey async {
    final s = await AiKeyStore.instance.read();
    return (s.$1?.isNotEmpty ?? false) ||
        (s.$2?.isNotEmpty ?? false) ||
        deepSeekApiKey.isNotEmpty ||
        geminiApiKey.isNotEmpty;
  }
}
