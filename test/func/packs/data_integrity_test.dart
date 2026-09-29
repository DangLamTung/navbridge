/// Automated data integrity tests for NavBridge offline datasets.
///
/// Validates:
///   1. Bundled and update datasets are non-empty and well-formed.
///   2. Geographic coordinates strictly fall within the Vietnam bbox.
///   3. Spatial deduplication guarantees (no duplicate same-kind signs or
///      same-focus cameras within 80m).
///   4. Update release artifacts (manifest.json, version.json) match on-disk
///      files and SHA256 hashes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dp = (lat2 - lat1) * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.sqrt(a));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Bundled Data Integrity', () {
    test(
      'vietnam_signs.json meets data quality & deduplication guarantees',
      () async {
        final raw = await rootBundle.loadString(
          'assets/offline_map/vietnam_signs.json',
        );
        final doc = jsonDecode(raw) as Map<String, dynamic>;
        final signs = (doc['signs'] as List).cast<Map<String, dynamic>>();

        // The repo tracks a 15-byte stub (`{"signs":[]}`): the real DB is served
        // by the update server and kept locally with skip-worktree, so a clean
        // checkout has nothing to validate.
        if (signs.isEmpty) {
          markTestSkipped(
            'bundled sign DB is a stub (see tool/stub_assets.sh)',
          );
          return;
        }

        // 1. Minimum expected dataset volume
        expect(signs.length, greaterThan(40000));

        // 2. Coordinate range and field validity
        for (final s in signs) {
          final lat = (s['lat'] as num).toDouble();
          final lng = (s['lng'] as num).toDouble();
          expect(
            lat,
            inInclusiveRange(8.0, 24.0),
            reason: 'lat out of VN bbox',
          );
          expect(
            lng,
            inInclusiveRange(102.0, 110.0),
            reason: 'lng out of VN bbox',
          );
          expect(s['kind'], isNotNull);
          if (s['kind'] == 'speed') {
            final val = (s['value'] as num?)?.toInt();
            expect(val, isNotNull);
            expect(
              val,
              inInclusiveRange(5, 200),
              reason: 'unreasonable speed limit',
            );
          }
        }

        // 3. Spatial deduplication: 0 same-kind duplicates within 80m
        signs.sort((a, b) => (a['lat'] as num).compareTo(b['lat'] as num));
        var dupsWithin80m = 0;
        for (var i = 0; i < signs.length; i++) {
          final s1 = signs[i];
          final lat1 = (s1['lat'] as num).toDouble();
          final lng1 = (s1['lng'] as num).toDouble();
          final kind1 = s1['kind'];

          for (var j = i + 1; j < signs.length; j++) {
            final s2 = signs[j];
            final lat2 = (s2['lat'] as num).toDouble();
            if ((lat2 - lat1) * 111000 > 80) break; // lat window exceeded
            if (s2['kind'] == kind1) {
              final lng2 = (s2['lng'] as num).toDouble();
              final d = _haversineDistance(lat1, lng1, lat2, lng2);
              if (d <= 80) dupsWithin80m++;
            }
          }
        }
        expect(
          dupsWithin80m,
          equals(0),
          reason: 'Found duplicate same-kind signs within 80 meters',
        );
      },
    );

    test(
      'vietnam_cameras.json meets data quality & deduplication guarantees',
      () async {
        final raw = await rootBundle.loadString(
          'assets/offline_map/vietnam_cameras.json',
        );
        final doc = jsonDecode(raw) as Map<String, dynamic>;
        final cams = (doc['cameras'] as List).cast<Map<String, dynamic>>();

        // Same stub caveat as vietnam_signs.json above.
        if (cams.isEmpty) {
          markTestSkipped(
            'bundled camera DB is a stub (see tool/stub_assets.sh)',
          );
          return;
        }

        expect(cams.length, greaterThan(25000));

        for (final c in cams) {
          final lat = (c['lat'] as num).toDouble();
          final lng = (c['lng'] as num).toDouble();
          expect(lat, inInclusiveRange(8.0, 24.0));
          expect(lng, inInclusiveRange(102.0, 110.0));
          expect([
            'speed',
            'red_light',
            'violations',
            'sign',
          ], contains(c['focus']));
        }

        // Spatial deduplication: 0 same-focus duplicates within 80m
        cams.sort((a, b) => (a['lat'] as num).compareTo(b['lat'] as num));
        var dupsWithin80m = 0;
        for (var i = 0; i < cams.length; i++) {
          final c1 = cams[i];
          final lat1 = (c1['lat'] as num).toDouble();
          final lng1 = (c1['lng'] as num).toDouble();
          final focus1 = c1['focus'];

          for (var j = i + 1; j < cams.length; j++) {
            final c2 = cams[j];
            final lat2 = (c2['lat'] as num).toDouble();
            if ((lat2 - lat1) * 111000 > 80) break;
            if (c2['focus'] == focus1) {
              final lng2 = (c2['lng'] as num).toDouble();
              final d = _haversineDistance(lat1, lng1, lat2, lng2);
              if (d <= 80) dupsWithin80m++;
            }
          }
        }
        expect(
          dupsWithin80m,
          equals(0),
          reason: 'Found duplicate same-focus cameras within 80 meters',
        );
      },
    );
  });

  group('Update Server Release Quality', () {
    test(
      'update/latest matches manifest.json, version.json and disk files',
      () {
        final latestDir = Directory('update/latest');
        if (!latestDir.existsSync()) return;

        final manifestFile = File('update/latest/manifest.json');
        final versionFile = File('update/latest/version.json');
        expect(manifestFile.existsSync(), isTrue);
        expect(versionFile.existsSync(), isTrue);

        final manifest =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        final version =
            jsonDecode(versionFile.readAsStringSync()) as Map<String, dynamic>;

        expect(manifest['files'], isNotNull);
        expect(version['cameras'], isNotNull);
        expect(version['signs'], isNotNull);
        expect(version['speed_limits'], isNotNull);

        final files = manifest['files'] as Map<String, dynamic>;
        for (final entry in files.entries) {
          final f = File('update/latest/${entry.key}');
          expect(
            f.existsSync(),
            isTrue,
            reason: 'Missing release file ${entry.key}',
          );
          final bytes = f.readAsBytesSync();
          final meta = entry.value as Map<String, dynamic>;
          expect(bytes.length, equals(meta['size']));
          final hash = sha256.convert(bytes).toString();
          expect(hash, equals(meta['sha256']));
        }
      },
    );
  });
}
