/// A graph folder that cannot load must be recognisable WITHOUT asking
/// GraphHopper: the phone that motivated this (itel_P663LN, 2026-09-30) carried a
/// 249.6 MB folder from an interrupted import, the Offline screen reported
/// "Bộ dữ liệu đã có", and every load threw `Not a GraphHopper file … Expected
/// 'GH' as file marker`. These tests pin the marker rule that now catches it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_router.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nb_graph_marker'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('graphPropertiesMarkerOk', () {
    test('accepts a file starting with the GH marker', () {
      final f = File('${tmp.path}/properties')
        ..writeAsBytesSync([0x47, 0x48, 0x01, 0x00, 0x02]);
      expect(graphPropertiesMarkerOk(f), isTrue);
    });

    test('rejects an EMPTY properties file — the interrupted-import case', () {
      // The import creates `properties` before it writes anything, so a process
      // killed mid-build leaves exactly this.
      final f = File('${tmp.path}/properties')..writeAsBytesSync([]);
      expect(graphPropertiesMarkerOk(f), isFalse);
    });

    test('rejects a missing file, and a file with other content', () {
      expect(graphPropertiesMarkerOk(File('${tmp.path}/properties')), isFalse);
      final other = File('${tmp.path}/properties')..writeAsStringSync('XX');
      expect(graphPropertiesMarkerOk(other), isFalse);
      // One byte only — a truncated header is not a header.
      final one = File('${tmp.path}/properties')..writeAsBytesSync([0x47]);
      expect(graphPropertiesMarkerOk(one), isFalse);
    });
  });

  group('graphFolderCorrupt', () {
    test('false when there is no folder at all', () async {
      expect(await graphFolderCorrupt('${tmp.path}/routing_graph'), isFalse);
    });

    test('false for an empty folder (that is "not installed")', () async {
      final d = Directory('${tmp.path}/routing_graph')..createSync();
      expect(await graphFolderCorrupt(d.path), isFalse);
    });

    test('true for a populated folder with an unmarked properties', () async {
      final d = Directory('${tmp.path}/routing_graph')..createSync();
      File('${d.path}/edges').writeAsBytesSync(List.filled(16, 7));
      File('${d.path}/properties').writeAsBytesSync([]);
      expect(await graphFolderCorrupt(d.path), isTrue);
    });

    test('false for a populated folder with a marked properties', () async {
      final d = Directory('${tmp.path}/routing_graph')..createSync();
      File('${d.path}/edges').writeAsBytesSync(List.filled(16, 7));
      File('${d.path}/properties').writeAsBytesSync([0x47, 0x48, 0x09]);
      expect(await graphFolderCorrupt(d.path), isFalse);
    });

    test('false when a wrapper directory holds the graph (.ghz with a '
        'top-level folder inside)', () async {
      // Extraction keeps the archive's own layout, so the graph can sit one
      // level down. Treating that as debris would make the self-healing loader
      // delete a perfectly good graph.
      final d = Directory('${tmp.path}/routing_graph/vietnam_graph')
        ..createSync(recursive: true);
      File('${d.path}/edges').writeAsBytesSync(List.filled(16, 7));
      File('${d.path}/properties').writeAsBytesSync([0x47, 0x48]);
      expect(await graphFolderCorrupt('${tmp.path}/routing_graph'), isFalse);
    });

    test('true when the wrapper directory is itself unmarked', () async {
      final d = Directory('${tmp.path}/routing_graph/vietnam_graph')
        ..createSync(recursive: true);
      File('${d.path}/edges').writeAsBytesSync(List.filled(16, 7));
      File('${d.path}/properties').writeAsBytesSync([]);
      expect(await graphFolderCorrupt('${tmp.path}/routing_graph'), isTrue);
    });
  });
}
