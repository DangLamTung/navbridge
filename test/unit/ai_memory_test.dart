import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:navbridge/core/ai_memory.dart';
import 'package:navbridge/services/ai_assistant.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aimem_test');
    AiMemory.debugFileOverride = File('${tmp.path}/ai_memory.json');
    AiMemory.instance.resetForTest();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    AiMemory.debugFileOverride = null;
  });

  test('"nhớ …" stores a fact and "nhớ gì" lists it', () async {
    final r1 = await handleMemoryIntent('nhớ tôi đi xe máy');
    expect(r1, contains('Đã nhớ'));
    final r2 = await handleMemoryIntent('nhớ gì?');
    expect(r2, contains('tôi đi xe máy'));
  });

  test('"quên …" removes matching facts', () async {
    await handleMemoryIntent('nhớ thích cà phê võng');
    await handleMemoryIntent('nhớ đi xe máy');
    final gone = await handleMemoryIntent('quên cà phê');
    expect(gone, contains('Đã quên'));
    final facts = await AiMemory.instance.facts;
    expect(facts, isNot(contains('thích cà phê võng')));
    expect(facts, contains('đi xe máy'));
  });

  test('normal questions are not treated as memory commands', () async {
    expect(await handleMemoryIntent('hỏi ai xăng gần nhất'), isNull);
    expect(await handleMemoryIntent('thời tiết thế nào'), isNull);
  });

  test('facts persist across a reload', () async {
    await handleMemoryIntent('nhớ tên tôi là Nam');
    // Simulate a fresh instance by resetting (keeps the same backing file).
    AiMemory.instance.resetForTest();
    final facts = await AiMemory.instance.facts;
    expect(facts, contains('tên tôi là Nam'));
  });

  test('duplicate facts are de-duped (diacritic-insensitive)', () async {
    await handleMemoryIntent('nhớ tôi đi xe máy');
    await handleMemoryIntent('nhớ tôi đi xe may');
    final facts = await AiMemory.instance.facts;
    expect(facts.where((f) => f.contains('xe máy')).length, 1);
  });

  test('memory stays light: capped fact count and prompt length', () async {
    final m = AiMemory.instance;
    for (var i = 0; i < 50; i++) {
      await m.remember('điểm đến quen thuộc số $i');
    }
    final facts = await m.facts;
    expect(facts.length, lessThanOrEqualTo(20));
    final prompt = await m.factsPrompt();
    expect(prompt.length, lessThanOrEqualTo(1550));
  });

  test('AiAssistant trims long session history to stay light', () {
    final a = AiAssistant.instance;
    final long = 'x' * 1000;

    // > 12 turns → keeps the last 12.
    final many = [for (var i = 0; i < 20; i++) (isUser: true, text: 'q$i')];
    final trimmedMany = a.trimHistoryForTest(many);
    expect(trimmedMany.length, 12);
    expect(trimmedMany.first.text, 'q8');

    // > 6000 chars → drops oldest until under budget.
    final heavy = [for (var i = 0; i < 8; i++) (isUser: i.isEven, text: long)];
    final trimmedHeavy = a.trimHistoryForTest(heavy);
    final total = trimmedHeavy.fold<int>(0, (s, t) => s + t.text.length);
    expect(total, lessThanOrEqualTo(6000));
    expect(trimmedHeavy.length, greaterThan(0));
  });
}
