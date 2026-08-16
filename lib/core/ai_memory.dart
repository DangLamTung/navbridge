/// Lightweight persistent memory for the AI assistant.
///
/// Stores a small list of short driver preferences/facts on disk (e.g.
/// "tôi đi xe máy", "thích cà phê võng") and injects them into the
/// assistant's system prompt so it remembers across app restarts.
///
/// Kept deliberately light: max 20 facts, each capped at ~120 chars, total
/// prompt block capped at ~1500 chars, and NO extra API calls (facts are
/// written by the driver's "nhớ ..." command, not by the model).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

class AiMemory {
  AiMemory._();
  static final AiMemory instance = AiMemory._();

  static const int _maxFacts = 20;
  static const int _maxFactLen = 120;
  static const int _maxPromptChars = 1500;

  /// Test hook: point storage at a temp file instead of the app support dir.
  @visibleForTesting
  static File? debugFileOverride;

  final List<String> _facts = [];
  bool _loaded = false;
  File? _file;

  Future<File> _fileFor() async {
    if (_file != null) return _file!;
    final f =
        debugFileOverride ??
        File('${(await getApplicationSupportDirectory()).path}/ai_memory.json');
    return _file = f;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _fileFor();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as List<dynamic>;
      _facts
        ..clear()
        ..addAll(j.whereType<String>().take(_maxFacts));
    } catch (_) {
      // corrupt/missing file → start empty
    }
  }

  Future<void> save() async {
    try {
      final f = await _fileFor();
      await f.writeAsString(jsonEncode(_facts), flush: true);
    } catch (_) {}
  }

  /// Remember a fact (de-duped by normalized text; oldest dropped at cap).
  Future<void> remember(String fact) async {
    await _ensureLoaded();
    final f = fact.trim();
    if (f.isEmpty) return;
    final short = f.length <= _maxFactLen
        ? f
        : '${f.substring(0, _maxFactLen - 1)}…';
    final norm = _norm(short);
    final idx = _facts.indexWhere((x) => _norm(x) == norm);
    if (idx >= 0) {
      _facts[idx] = short;
    } else {
      _facts.add(short);
      if (_facts.length > _maxFacts) _facts.removeAt(0);
    }
    await save();
  }

  /// Remove every fact whose normalized text contains [keyword].
  Future<void> forget(String keyword) async {
    await _ensureLoaded();
    final k = _norm(keyword);
    if (k.isEmpty) return;
    final before = _facts.length;
    _facts.removeWhere((x) => _norm(x).contains(k));
    if (_facts.length != before) await save();
  }

  Future<void> clear() async {
    await _ensureLoaded();
    _facts.clear();
    await save();
  }

  Future<List<String>> get facts async {
    await _ensureLoaded();
    return List.unmodifiable(_facts);
  }

  /// Compact block to inject into the system prompt. Empty when no memory.
  Future<String> factsPrompt() async {
    await _ensureLoaded();
    if (_facts.isEmpty) return '';
    final joined = _facts.join('; ');
    final capped = joined.length <= _maxPromptChars
        ? joined
        : joined.substring(0, _maxPromptChars - 1);
    return 'Những điều đã nhớ về tài xế: $capped.';
  }

  @visibleForTesting
  void resetForTest() {
    _facts.clear();
    _loaded = false;
    _file = null;
  }

  /// Normalize for de-dupe/search: lowercase, drop diacritics & punctuation.
  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'đ'), 'd')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Handles driver memory commands locally (no API call — keeps it light):
///   `"nhớ <điều gì>"`    → remember a fact
///   `"quên <từ khoá>"`    → forget matching fact(s)
///   `"nhớ gì?"`           → list what's remembered
/// Returns a reply to show, or null when the text is not a memory command.
Future<String?> handleMemoryIntent(String text) async {
  final t = text.trim().toLowerCase();
  if (t.contains('nhớ gì') || t.contains('remember what')) {
    final fs = await AiMemory.instance.facts;
    if (fs.isEmpty) return 'Mình chưa nhớ điều gì đặc biệt về bạn.';
    return 'Mình đang nhớ: ${fs.join('; ')}.';
  }
  if (t.startsWith('quên ') || t.startsWith('forget ')) {
    final kw = text.trim().substring(4).trim();
    if (kw.isEmpty) return null;
    final before = await AiMemory.instance.facts;
    await AiMemory.instance.forget(kw);
    final after = await AiMemory.instance.facts;
    if (before.length == after.length) {
      return 'Mình không thấy điều gì khớp với "$kw".';
    }
    return 'Đã quên "$kw".';
  }
  if (t.startsWith('nhớ ') || t.startsWith('remember ')) {
    final fact = text.trim().substring(4).trim();
    if (fact.isEmpty) return null;
    await AiMemory.instance.remember(fact);
    return 'Đã nhớ: $fact.';
  }
  return null;
}
