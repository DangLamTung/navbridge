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

  /// Read both stored keys as (deepseek, gemini). Missing → null.
  Future<(String?, String?)> read() async {
    try {
      final d = await _storage.read(key: _kDeepSeek);
      final g = await _storage.read(key: _kGemini);
      return (d, g);
    } catch (_) {
      return (null, null);
    }
  }

  /// Store (or clear) the DeepSeek key. Empty string clears it.
  Future<void> saveDeepSeek(String key) async {
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _kDeepSeek);
      } else {
        await _storage.write(key: _kDeepSeek, value: key);
      }
    } catch (_) {}
  }

  /// Store (or clear) the Gemini key. Empty string clears it.
  Future<void> saveGemini(String key) async {
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _kGemini);
      } else {
        await _storage.write(key: _kGemini, value: key);
      }
    } catch (_) {}
  }

  /// Clear both stored keys.
  Future<void> clear() async {
    try {
      await _storage.delete(key: _kDeepSeek);
      await _storage.delete(key: _kGemini);
    } catch (_) {}
  }
}
