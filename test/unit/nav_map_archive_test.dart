/// Guards for installing a nav-map archive.
///
/// The picker path used `FileType.custom` with `['pmtiles']`, which **throws on
/// Android before the picker opens** (file_picker maps extensions to MIME types via
/// MimeTypeMap; `.pmtiles` has none, so the allowed list is empty). Confirmed on the
/// itel_P663LN on 2026-09-30. These tests cover the content guard that now backs the
/// extension check, so a wrong pick cannot be installed and then fail silently.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/nav_map_store.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nb_pmtiles'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<int> pmtilesHeader({int extra = 200}) => [
    ...kPmTilesMagic,
    ...List.filled(extra, 0),
  ];

  group('pmtilesLooksValid', () {
    test('accepts a file starting with the PMTiles magic', () {
      final f = File('${tmp.path}/vietnam_z14.pmtiles')
        ..writeAsBytesSync(pmtilesHeader());
      expect(pmtilesLooksValid(f), isTrue);
    });

    test('rejects a file with the wrong magic', () {
      final f = File('${tmp.path}/routing_graph.ghz')
        ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04, ...List.filled(200, 0)]);
      expect(pmtilesLooksValid(f), isFalse);
    });

    test('rejects a Git-LFS pointer or any short text file', () {
      final f = File('${tmp.path}/pointer.pmtiles')
        ..writeAsStringSync('version https://git-lfs.github.com/spec/v1\n');
      expect(pmtilesLooksValid(f), isFalse);
    });

    test('rejects a file smaller than the 127-byte header', () {
      final f = File('${tmp.path}/tiny.pmtiles')
        ..writeAsBytesSync(kPmTilesMagic);
      expect(pmtilesLooksValid(f), isFalse);
    });

    test('rejects a missing file', () {
      expect(pmtilesLooksValid(File('${tmp.path}/nope.pmtiles')), isFalse);
    });

    test('a truncated archive still passes the magic test (documented limit)',
        () {
      // Truncation is NOT caught here — the header is intact. That is deliberate:
      // this guards against the WRONG FILE, while completeness is the transfer's
      // job (byte count, and the app copies with the picker's cache in between).
      final full = File('${tmp.path}/a.pmtiles')..writeAsBytesSync(pmtilesHeader());
      expect(pmtilesLooksValid(full), isTrue);
    });
  });
}
