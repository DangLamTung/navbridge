/// The Google API meter: month rollover, free-cap arithmetic and the text the
/// settings card shows. No network, no key — the counters are local by design
/// (Google exposes no "calls remaining" endpoint).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/api_usage.dart';

void main() {
  setUp(() {
    ApiUsage.resetForTest();
    ApiUsage.fileOverrideForTest = null;
  });

  tearDown(ApiUsage.resetForTest);

  group('pure helpers', () {
    test('monthKey is zero-padded and rolls over', () {
      expect(monthKey(DateTime(2026, 1, 5)), '2026-01');
      expect(monthKey(DateTime(2026, 10, 21)), '2026-10');
      expect(monthKey(DateTime(2026, 12, 31)), '2026-12');
    });

    test('remainingOf stops at zero and is null for free SKUs', () {
      const dirs = GoogleSku('directions', 'x', 5000, 10);
      expect(remainingOf(dirs, 0), 5000);
      expect(remainingOf(dirs, 4999), 1);
      expect(remainingOf(dirs, 5000), 0);
      expect(remainingOf(dirs, 7000), 0); // never negative
      const details = GoogleSku('place_details', 'x', 0, 0);
      expect(remainingOf(details, 12345), isNull);
    });

    test('costOf only charges the events past the free cap', () {
      const dirs = GoogleSku('directions', 'x', 5000, 10);
      expect(costOf(dirs, 5000), 0);
      expect(costOf(dirs, 6000), closeTo(10, 0.001));
      expect(costOf(dirs, 5500), closeTo(5, 0.001));
      const free = GoogleSku('place_details', 'x', 0, 0);
      expect(costOf(free, 99999), 0);
    });

    test('usageText shows the cap, then the overage cost', () {
      const dirs = GoogleSku('directions', 'x', 5000, 10);
      expect(usageText(dirs, 12), '12 / 5000');
      expect(usageText(dirs, 6000), contains('vượt hạn mức'));
      expect(usageText(dirs, 6000), contains(r'$10.00'));
      expect(
        usageText(const GoogleSku('p', 'x', 0, 0), 7),
        contains('miễn phí'),
      );
    });

    test('every SKU id resolves, and labels are distinct', () {
      for (final s in googleSkus) {
        expect(skuById(s.id)?.id, s.id);
      }
      expect(skuById('nope'), isNull);
      final labels = googleSkus.map((s) => s.label).toSet();
      expect(labels.length, googleSkus.length);
    });
  });

  group('ledger', () {
    late Directory tmp;
    late File file;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('api_usage_test');
      file = File('${tmp.path}/api_usage.json');
      ApiUsage.fileOverrideForTest = file;
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('counts per SKU and survives a reload', () async {
      ApiUsage.clock = () => DateTime(2026, 10, 21);
      await ApiUsage.note('directions');
      await ApiUsage.note('directions', n: 2);
      await ApiUsage.note('geocode');
      expect(ApiUsage.usedOf('directions'), 3);
      expect(ApiUsage.usedOf('geocode'), 1);
      expect(ApiUsage.hasAny, isTrue);

      await ApiUsage.flush();
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('2026-10'));

      // A fresh process (reset) must read the same numbers back.
      ApiUsage.resetForTest();
      ApiUsage.fileOverrideForTest = file;
      await ApiUsage.load();
      expect(ApiUsage.usedOf('directions'), 3);
      expect(ApiUsage.usedOf('geocode'), 1);
    });

    test(
      'a new month starts from zero instead of carrying the old counts',
      () async {
        ApiUsage.clock = () => DateTime(2026, 10, 31);
        await ApiUsage.note('directions', n: 5);
        await ApiUsage.flush();

        // Same file, next month: the persisted 5 must NOT leak forward.
        ApiUsage.resetForTest();
        ApiUsage.fileOverrideForTest = file;
        ApiUsage.clock = () => DateTime(2026, 11, 1);
        await ApiUsage.load();
        expect(ApiUsage.usedOf('directions'), 0);

        await ApiUsage.note('directions');
        expect(ApiUsage.usedOf('directions'), 1);
      },
    );

    test('rolls over in-process without a restart', () async {
      var now = DateTime(2026, 10, 31, 23, 59);
      ApiUsage.clock = () => now;
      await ApiUsage.note('routes_pro', n: 9);
      expect(ApiUsage.usedOf('routes_pro'), 9);

      now = DateTime(2026, 11, 1, 0, 1);
      await ApiUsage.note('routes_pro');
      expect(ApiUsage.usedOf('routes_pro'), 1);
    });

    test(
      'a corrupt file degrades to an empty meter instead of throwing',
      () async {
        file.writeAsStringSync('{not json');
        ApiUsage.fileOverrideForTest = file;
        await ApiUsage.load();
        expect(ApiUsage.usedOf('directions'), 0);
        await ApiUsage.note('directions');
        expect(ApiUsage.usedOf('directions'), 1);
      },
    );
  });
}
