/// The source-choosing rule, tested without a phone.
///
/// This is the fix for the itel_P663LN dead end (2026-09-30): a 249.6 MB folder
/// left by an interrupted import had no `GH` marker, so GraphHopper could never
/// open it — yet it outranked the `.pbf` beside it, so every load threw and there
/// was no way out from inside the app. A populated folder may only win when it is
/// loadable.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_router.dart';

void main() {
  const dir = '/app/files/routing_graph';

  group('graphSourcePath', () {
    test('a loadable folder wins over every sibling', () {
      expect(
        graphSourcePath(
          dir: dir,
          populated: true,
          loadable: true,
          siblings: ['$dir.ghz', '$dir.osm.pbf'],
        ),
        dir,
      );
    });

    test('an unloadable folder loses to the sibling archive', () {
      // The whole bug in one assertion: debris must not shadow the fix.
      expect(
        graphSourcePath(
          dir: dir,
          populated: true,
          loadable: false,
          siblings: ['$dir.ghz'],
        ),
        '$dir.ghz',
      );
    });

    test('an empty folder with no sibling stays the target (to import into)', () {
      expect(
        graphSourcePath(
          dir: dir,
          populated: false,
          loadable: false,
          siblings: const [],
        ),
        dir,
      );
    });

    test('an empty folder still defers to a sibling source', () {
      expect(
        graphSourcePath(
          dir: dir,
          populated: false,
          loadable: false,
          siblings: ['$dir.osm.pbf'],
        ),
        '$dir.osm.pbf',
      );
    });

    test('a folder that is populated but unmarked and alone is still returned', () {
      expect(
        graphSourcePath(
          dir: dir,
          populated: true,
          loadable: false,
          siblings: const [],
        ),
        dir,
      );
    });
  });

  group('graphSiblingSources', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nb_sibling'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('empty when nothing sits beside the folder', () {
      expect(graphSiblingSources('${tmp.path}/routing_graph'), isEmpty);
    });

    test('prefers a complete .ghz, then .zip, then a PBF', () {
      final base = '${tmp.path}/routing_graph';
      File('$base.osm.pbf').writeAsBytesSync([1]);
      expect(graphSiblingSources(base), ['$base.osm.pbf']);

      _writeCompleteZip(File('$base.zip'));
      expect(graphSiblingSources(base), ['$base.zip', '$base.osm.pbf']);

      // Unzipping beats importing, so the archive must come first.
      _writeCompleteZip(File('$base.ghz'));
      expect(graphSiblingSources(base), [
        '$base.ghz',
        '$base.zip',
        '$base.osm.pbf',
      ]);
    });

    test('a TRUNCATED archive is not offered to the loader', () {
      // The itel_P663LN failure: a .ghz copied mid-`adb push` was the right name
      // and even the right length to look plausible, but had no zip end record,
      // so GraphHopper answered "zip END header not found".
      final base = '${tmp.path}/routing_graph';
      final truncated = File('$base.ghz')
        ..writeAsBytesSync(List.filled(4096, 7));
      expect(zipComplete(truncated), isFalse);
      expect(graphSiblingSources(base), isEmpty);
    });
  });

  group('zipComplete', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nb_zip'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('true for an archive with the end-of-central-directory record', () {
      final f = File('${tmp.path}/a.ghz');
      _writeCompleteZip(f);
      expect(zipComplete(f), isTrue);
    });

    test('false for an empty, tiny or markerless file', () {
      expect(zipComplete(File('${tmp.path}/missing')), isFalse);
      final empty = File('${tmp.path}/e')..writeAsBytesSync([]);
      expect(zipComplete(empty), isFalse);
      final junk = File('${tmp.path}/j')
        ..writeAsBytesSync(List.filled(64, 0x41));
      expect(zipComplete(junk), isFalse);
    });
  });
}

/// Writes a file that ENDS with the zip end-of-central-directory record, which
/// is what [zipComplete] looks for. Filler bytes stand in for the archive body —
/// the check is about completeness, not content.
void _writeCompleteZip(File f) {
  final eocd = <int>[
    0x50, 0x4b, 0x05, 0x06, // 'PK\x05\x06'
    ...List.filled(18, 0),
  ];
  f.writeAsBytesSync([...List.filled(64, 0x42), ...eocd]);
}
