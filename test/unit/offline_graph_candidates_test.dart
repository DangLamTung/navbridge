/// The app must not depend on WHAT a downloaded file is called.
///
/// `vitnam-260928.osm.pbf` — the file actually sitting on the test phone — matched
/// none of the hard-coded names (`vietnam-latest.osm.pbf`, `graph.ghz`, …), so the
/// app reported "no offline data" while the extract was right there. Only the
/// extension is consulted now.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_router.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nb_candidates'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File put(String name, {int bytes = 8, Duration? age}) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
    if (age != null) {
      final t = DateTime.now().subtract(age);
      f.setLastModifiedSync(t);
    }
    return f;
  }

  group('graphCandidatesIn', () {
    test('finds an arbitrarily named PBF', () {
      put('vietnam-260928.osm.pbf');
      final found = graphCandidatesIn(tmp.path);
      expect(found, hasLength(1));
      expect(found.single, endsWith('vietnam-260928.osm.pbf'));
    });

    test('ignores files that are not map sources', () {
      put('notes.txt');
      put('holiday.jpg');
      put('routing_graph.json');
      expect(graphCandidatesIn(tmp.path), isEmpty);
    });

    test('an archive outranks a PBF, even an older one', () {
      // Unzipping a .ghz is minutes faster than importing a PBF, so it wins.
      final old = put('vietnam_graph.ghz', age: const Duration(days: 30));
      put('vietnam-260928.osm.pbf');
      expect(graphCandidatesIn(tmp.path).first, old.path);
    });

    test('among the same kind, the newest wins', () {
      final older = put('a.osm.pbf', age: const Duration(days: 2));
      final newer = put('b.osm.pbf');
      final found = graphCandidatesIn(tmp.path);
      expect(found, [newer.path, older.path]);
    });

    test('returns empty for a folder that does not exist', () {
      expect(graphCandidatesIn('${tmp.path}/nope'), isEmpty);
    });

    test('does not throw when the folder cannot be listed', () async {
      // Stands in for scoped storage denying a raw listing on Android 11+.
      final f = File('${tmp.path}/not-a-dir')..writeAsStringSync('x');
      expect(graphCandidatesIn(f.path), isEmpty);
      expect(await graphFolderCorrupt(f.path), isFalse);
    });
  });
}
