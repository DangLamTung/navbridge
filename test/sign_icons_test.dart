/// Only VERIFIED artwork may be shipped as a sign PNG.
///
/// The sign layer is drawn by `SignIcon`'s painters for almost every kind, with
/// bundled PNGs for the few whose real QCVN artwork was checked. That boundary
/// has already been broken twice — a STOP slot holding a no-entry photo, and a
/// U-turn slot holding the cấm-vượt sign — because both images passed the
/// geometry audit (`tools/signs/audit_all_signs.py`) while depicting the WRONG
/// SIGN. Only looking at them caught it (`tools/signs/sign_contact_sheet.py`).
/// These tests keep the list honest.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/ui/sign_icons.dart';

void main() {
  test(
    'kinds whose bundled PNG showed the wrong sign are painted, not imaged',
    () {
      const mustPaint = {
        // stop.png was a PHOTO of P.102 "cấm đi ngược chiều" (no entry) with a
        // vendor watermark — not the P.101 STOP octagon.
        RoadSignKind.stop,
        // give_way.png was a red-bordered CIRCLE with two arrows; P.132 is an
        // inverted triangle.
        RoadSignKind.giveWay,
        // no_passing.png was the xe-tải variant, which reads as "trucks only".
        RoadSignKind.noPassing,
        // end_prohibitions.png was two cars = P.135 "hết cấm vượt", not P.133.
        RoadSignKind.endProhibitions,
      };
      for (final kind in mustPaint) {
        expect(
          SignIcon.assetFor(kind),
          isNull,
          reason: '$kind must fall back to its painter',
        );
      }
    },
  );

  test('the turn prohibitions keep their verified artwork', () {
    // noUTurn is BACK on real artwork: Commons `Vietnam road sign P124a1.svg`
    // (public domain, "No U-turn to the left") replaced first the cấm-vượt image
    // that used to sit in this slot, then a sign we had drawn ourselves.
    for (final kind in [
      RoadSignKind.noLeftTurn,
      RoadSignKind.noRightTurn,
      RoadSignKind.noUTurn,
    ]) {
      expect(
        SignIcon.assetFor(kind),
        isNotNull,
        reason: '$kind lost its image',
      );
    }
  });

  test('every mapped asset exists, is non-trivial and is a PNG', () {
    const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    var mapped = 0;
    for (final kind in RoadSignKind.values) {
      final path = SignIcon.assetFor(kind);
      if (path == null) continue;
      mapped++;
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path is mapped but missing');
      expect(f.lengthSync(), greaterThan(1000), reason: '$path looks empty');
      expect(
        f.readAsBytesSync().sublist(0, 8),
        pngMagic,
        reason: '$path is not a PNG',
      );
    }
    expect(mapped, greaterThan(0), reason: 'no artwork is used at all');
  });

  test(
    'no bundled sign PNG is left unused (it could be re-mapped by mistake)',
    () {
      final dir = Directory('assets/offline_map/signs');
      if (!dir.existsSync()) return;
      final mapped = {
        for (final kind in RoadSignKind.values)
          if (SignIcon.assetFor(kind) != null)
            SignIcon.assetFor(kind)!.split('/').last,
      };
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.path.split(Platform.pathSeparator).last;
        expect(
          mapped,
          contains(name),
          reason: '$name is bundled but shown for no kind — delete or map it',
        );
      }
    },
  );
}
