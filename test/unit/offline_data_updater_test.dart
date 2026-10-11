/// The offline data auto-updater — which packs sync, and what is accepted.
///
/// Regression guard. The posted-limit files were published and versioned by the
/// server for months while the client consumed nothing, and the segment layer
/// (the app's primary posted-limit authority) was excluded outright as "too
/// large". Either way a limit-data fix could not reach a device without a new
/// APK. One list now drives the sync, and these tests stop it drifting again.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_data_updater.dart'
    show kUpdatePackLabels, kUpdatePacks, saneUpdatePack;

/// Every key `tools/update_server.py` writes into `version.json`. If the server
/// starts versioning a new pack and the client is not taught to fetch it, this
/// list and [kUpdatePacks] disagree and the test fails.
const _serverVersionKeys = <String>{
  'cameras',
  'signs',
  'speed_limits',
  'vietmap_limits',
  'pois',
  'places',
  'nav_style',
  'overview_tiles',
  'segments',
};

Uint8List _b(List<int> xs) => Uint8List.fromList(xs);

void main() {
  group('kUpdatePacks', () {
    test('covers every key the server versions — no orphaned pack', () {
      final keys = kUpdatePacks.map((p) => p.$1).toSet();
      expect(
        keys,
        _serverVersionKeys,
        reason: 'a versioned pack that nothing fetches stays stale forever',
      );
    });

    test('syncs the segment layer — the posted-limit authority', () {
      final seg = kUpdatePacks.where((p) => p.$2 == 'waze_segments.bin');
      expect(seg, hasLength(1));
      expect(seg.first.$1, 'segments');
    });

    test('keys and filenames are unique and non-empty', () {
      expect(
        kUpdatePacks.map((p) => p.$1).toSet(),
        hasLength(kUpdatePacks.length),
      );
      expect(
        kUpdatePacks.map((p) => p.$2).toSet(),
        hasLength(kUpdatePacks.length),
      );
      for (final (key, file) in kUpdatePacks) {
        expect(key, isNotEmpty);
        expect(file, isNotEmpty);
      }
    });

    test('every pack has a sane() rule that its own bytes can satisfy', () {
      // A pack whose filename matches no branch falls through to JSON parsing,
      // which silently rejects any binary pack.
      for (final (_, file) in kUpdatePacks) {
        final isBinary = file.endsWith('.bin') || file.endsWith('.tar.gz');
        final bytes = file.endsWith('.bin')
            ? _b([0x57, 0x5a, 0x53, 0x47, 3, 0, 0, 0, 0, 0])
            : file.endsWith('.tar.gz')
            ? _b([0x1f, 0x8b, 8, 0])
            : utf8.encode('{"ok":1}');
        expect(
          saneUpdatePack(file, bytes),
          isTrue,
          reason: '$file must be accepted as ${isBinary ? 'binary' : 'JSON'}',
        );
      }
    });

    test('every pack has a display label — the UI names what changed', () {
      // The offline screen describes an update by naming the packs that came
      // down. A key with no label would show the driver a raw snake_case
      // identifier, so every key must resolve to readable Vietnamese.
      for (final (key, _) in kUpdatePacks) {
        expect(kUpdatePackLabels[key], isNotNull, reason: '$key has no label');
        expect(kUpdatePackLabels[key], isNotEmpty, reason: '$key is blank');
      }
    });

    test('no label exists for a pack that is not synced', () {
      expect(
        kUpdatePackLabels.keys.toSet(),
        kUpdatePacks.map((p) => p.$1).toSet(),
      );
    });
  });

  group('saneUpdatePack', () {
    test('rejects an empty body', () {
      expect(saneUpdatePack('vietnam_signs.json', _b([])), isFalse);
      expect(saneUpdatePack('waze_segments.bin', _b([])), isFalse);
    });

    test('accepts a JSON object, and the ARRAY that places actually is', () {
      expect(
        saneUpdatePack('vietnam_signs.json', utf8.encode('{"a":1}')),
        isTrue,
      );
      expect(
        saneUpdatePack('vietnam_places.json', utf8.encode('[{"n":1}]')),
        isTrue,
      );
    });

    test('rejects an HTML error page served with HTTP 200', () {
      expect(
        saneUpdatePack('vietnam_signs.json', utf8.encode('<html>404</html>')),
        isFalse,
      );
    });

    test('the segment layer needs the WZSG magic, not JSON', () {
      // The bug this guards: JSON validation rejected the binary pack, so even
      // a correct download could never be written to disk.
      final wzsg = _b([0x57, 0x5a, 0x53, 0x47, 3, 0, 0, 0, 0, 0]);
      expect(saneUpdatePack('waze_segments.bin', wzsg), isTrue);
      expect(
        saneUpdatePack('waze_segments.bin', utf8.encode('{"a":1}')),
        isFalse,
      );
      expect(saneUpdatePack('waze_segments.bin', _b([0x57, 0x5a])), isFalse);
    });

    test('the tile archive needs gzip magic', () {
      expect(
        saneUpdatePack('overview_tiles.tar.gz', _b([0x1f, 0x8b, 8, 0])),
        isTrue,
      );
      expect(
        saneUpdatePack('overview_tiles.tar.gz', utf8.encode('{"a":1}')),
        isFalse,
      );
    });
  });
}
