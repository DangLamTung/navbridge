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
  test('every kind a data source can emit draws official QCVN artwork', () {
    // The kinds the three generators actually produce:
    //   Waze decode    — tools/signs/build_waze_signs.py   (TYPE_KIND)
    //   VietMap E-DOG  — tools/signs/build_vietmap.py      (EDOG_SIGN)
    //   DATMAP merge   — tools/signs/rebuild_waze_assets.py + the DATMAP tipos
    // A sign from EITHER source has to show the Vietnamese sign PICTURE, not one
    // of our painters (user: "waze sign and vietmap sign must aligned to the
    // vietnamese sign data png").
    const fromData = {
      // Waze decode
      RoadSignKind.noPassing,
      RoadSignKind.noPassingEnd,
      RoadSignKind.noLeftTurn,
      RoadSignKind.noRightTurn,
      RoadSignKind.noUTurn,
      RoadSignKind.noLeftUTurn,
      RoadSignKind.noRightUTurn,
      RoadSignKind.onlyStraight,
      RoadSignKind.onlyLeft,
      RoadSignKind.onlyRight,
      RoadSignKind.endProhibitions,
      // VietMap E-DOG
      RoadSignKind.slowDown,
      RoadSignKind.tunnel,
      RoadSignKind.railwayCrossing,
      // DATMAP / OSM extras that reach the map
      RoadSignKind.noAuto,
      RoadSignKind.oneWay,
      RoadSignKind.noMoto,
      RoadSignKind.noParking,
      RoadSignKind.stop,
      RoadSignKind.giveWay,
    };
    // The two exceptions, both deliberate:
    //   speed     — the sign is a white disc carrying the km/h from the DATA, so
    //               it must stay painted (`_SpeedPainter`);
    //   tollBooth — no QCVN sign for a toll plaza was found (Commons' I.428b/c
    //               are EV/gas stations), so it keeps its text chip and is NOT
    //               in the list above.
    for (final kind in fromData) {
      expect(
        SignIcon.assetFor(kind),
        isNotNull,
        reason: '$kind comes from the sign data but has no real artwork',
      );
    }
    expect(SignIcon.assetFor(RoadSignKind.speed), isNull,
        reason: 'a speed sign draws its own number');
  });

  test('the QCVN code on a kind is the code of the bundled PNG', () {
    // Codes that used to point at a DIFFERENT sign than the picture shown:
    //   no_passing was "P.127 cấm vượt"  — P.125 is the overtaking ban
    //                                      (Commons: both editions "No overtaking");
    //   no_u_turn  was "P.125 cấm quay đầu" — P.125 is the overtaking ban, so it
    //                                      now carries the P.124a of its artwork;
    //   only_*     were R.411 / R.412 / R.412a — those are lane-direction
    //                                      boards ("Lane for coaches" for R412a),
    //                                      not the mandatory-direction signs.
    expect(RoadSignKind.noPassing.label, startsWith('P.125'));
    expect(RoadSignKind.noPassingEnd.label, startsWith('P.133'));
    expect(RoadSignKind.endProhibitions.label, startsWith('P.135'));
    expect(RoadSignKind.noUTurn.label, startsWith('P.124a'));
    expect(RoadSignKind.onlyStraight.label, startsWith('R.301a'));
    expect(RoadSignKind.onlyLeft.label, startsWith('R.301e'));
    expect(RoadSignKind.onlyRight.label, startsWith('R.301d'));
    expect(RoadSignKind.noAuto.label, startsWith('P.103a'));
    expect(RoadSignKind.railwayCrossing.label, startsWith('W.242a'));
    expect(RoadSignKind.tunnel.label, startsWith('W.240'));
    expect(RoadSignKind.oneWay.label, startsWith('I.407a'));
  });

  test('the turn prohibitions keep their verified artwork', () {
    // noUTurn is BACK on real artwork: Commons `Vietnam road sign P124a1.svg`
    // (public domain, "No U-turn to the left") replaced first the cấm-vượt image
    // that used to sit in this slot, then a sign we had drawn ourselves.
    // The two combinations are the Commons `P124c` / `P124d`, metadata
    // "No left/right turn or U-turn" — and used to be painted as a
    // left/right arrow with a second U-turn arrow stacked over it, which is not
    // the real sign.
    for (final kind in [
      RoadSignKind.noLeftTurn,
      RoadSignKind.noRightTurn,
      RoadSignKind.noUTurn,
      RoadSignKind.noLeftUTurn,
      RoadSignKind.noRightUTurn,
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
