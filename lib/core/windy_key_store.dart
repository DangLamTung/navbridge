/// Encrypted on-device storage for the Windy API key — the same store as the AI
/// keys (`flutter_secure_storage` → Android Keystore / iOS Keychain), so a paid
/// key is never embedded in the APK nor written to git.
///
/// Why it exists: `WINDY_API_KEY` was build-time only (`--dart-define`, filled
/// from `.env` by `tool/env.sh`), so trying a key meant a rebuild. The runtime
/// prefers what is stored here and falls back to the build-time define as a dev
/// convenience — see [resolveWindyApiKey] in `services/weather.dart`.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class WindyKeyStore {
  WindyKeyStore._();
  static final WindyKeyStore instance = WindyKeyStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kWindy = 'weather_windy_key';

  /// In-memory cache. The secure read costs ~100-500 ms on the first hit
  /// (Android Keystore) and the weather path asks every 3 minutes, so the
  /// value is kept here and [_loaded] records that the storage was consulted —
  /// a cached `null` must not mean "read it again every time".
  String? _cache;
  bool _loaded = false;

  /// The stored key, or null when nothing is stored. Cached after the first read.
  Future<String?> read() async {
    if (_loaded) return _cache;
    try {
      _cache = await _storage.read(key: _kWindy);
    } catch (_) {
      _cache = null; // no secure storage (e.g. web) → build-time define wins
    }
    _loaded = true;
    return _cache;
  }

  /// The cached value without touching the (slow) secure storage. Null when not
  /// loaded yet or nothing is stored — use [read] when the answer must be real.
  String? get cached => _cache;

  /// Store the key, or clear it when [key] is blank.
  Future<void> save(String key) async {
    final k = key.trim();
    try {
      if (k.isEmpty) {
        await _storage.delete(key: _kWindy);
      } else {
        await _storage.write(key: _kWindy, value: k);
      }
    } catch (_) {
      // Keep the in-memory value anyway: the running app can use the key even
      // when the platform store refuses it (no Keystore on this device).
    }
    _cache = k.isEmpty ? null : k;
    _loaded = true;
  }

  /// Forget the stored key.
  Future<void> clear() => save('');

  /// Drop the in-memory cache so the next [read] hits the storage again.
  @visibleForTesting
  void resetCacheForTesting() {
    _cache = null;
    _loaded = false;
  }
}
