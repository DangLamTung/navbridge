/// Encrypted on-device storage for the AI API keys.
///
/// Keys are stored via `flutter_secure_storage` → Android Keystore / iOS
/// Keychain (encrypted at rest), so they are NOT embedded in the APK and
/// never written to git. Users paste their DeepSeek / Gemini keys once in
/// the app settings; the runtime falls back to build-time defines only when
/// nothing is stored yet (dev convenience).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AiKeyStore {
  AiKeyStore._();
  static final AiKeyStore instance = AiKeyStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kDeepSeek = 'ai_deepseek_key';
  static const _kGemini = 'ai_gemini_key';

  // In-memory cache: flutter_secure_storage (encryptedSharedPreferences +
  // Android Keystore) is SLOW on first read, and the AI path re-reads both
  // keys on EVERY ask(). Caching keeps the first response fast and avoids a
  // repeated 100–500 ms Keystore/SharedPreferences read per question.
  ({String? deepseek, String? gemini})? _cache;

  /// Read both stored keys as (deepseek, gemini). Missing → null.
  /// Cached in memory after the first read so the AI path is not slowed by
  /// the (expensive) secure-storage read on every ask().
  Future<(String?, String?)> read() async {
    if (_cache != null) {
      return (_cache!.deepseek, _cache!.gemini);
    }
    try {
      final d = await _storage.read(key: _kDeepSeek);
      final g = await _storage.read(key: _kGemini);
      _cache = (deepseek: d, gemini: g);
      return (d, g);
    } catch (_) {
      return (null, null);
    }
  }

  /// Clear the in-memory cache (after a write/delete the stored value changed).
  void invalidate() => _cache = null;

  /// Store (or clear) the DeepSeek key. Empty string clears it.
  Future<void> saveDeepSeek(String key) async {
    final prev = _cache;
    _cache = null;
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _kDeepSeek);
      } else {
        await _storage.write(key: _kDeepSeek, value: key);
      }
      _cache = (deepseek: key, gemini: prev?.gemini);
    } catch (_) {}
  }

  /// Store (or clear) the Gemini key. Empty string clears it.
  Future<void> saveGemini(String key) async {
    final prev = _cache;
    _cache = null;
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _kGemini);
      } else {
        await _storage.write(key: _kGemini, value: key);
      }
      _cache = (deepseek: prev?.deepseek, gemini: key);
    } catch (_) {}
  }

  /// Clear both stored keys.
  Future<void> clear() async {
    _cache = null;
    try {
      await _storage.delete(key: _kDeepSeek);
      await _storage.delete(key: _kGemini);
    } catch (_) {}
  }
}
