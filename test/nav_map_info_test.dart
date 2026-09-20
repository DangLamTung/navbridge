/// The nav map reads its own archive instead of trusting hard-coded facts.
///
/// Verified against the reference `pmtiles` reader: `saigon_z16.pmtiles` holds
/// tiles at z0–z16 (nothing above z16), while the nav camera sits at z19 — which
/// is why the style now declares the source's min/max zoom (so the renderer
/// overzooms z16 for the z17–z19 camera instead of asking for tiles that do not
/// exist) and why the coverage box comes from this file.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/nav_map_info.dart';

void main() {
  test('reads the bundled Saigon archive: its zoom range and bbox', () async {
    final info = await NavMapInfo.read(
      File('assets/offline_map/saigon_z16.pmtiles'),
    );
    expect(info, isNotNull, reason: 'bundled archive must be readable');
    expect(info!.minZoom, 0);
    expect(
      info.maxZoom,
      16,
      reason:
          'the nav camera runs to z19 — the source must declare maxzoom 16 '
          'so MapLibre overzooms instead of requesting missing z17+ tiles',
    );
    expect(info.tiles, greaterThan(3000));

    // bbox: central Saigon. The hard-coded coverage box was much wider
    // (10.40–11.20 / 106.30–107.10), so the app kept the vector style in the
    // ring between them — with no tiles to draw.
    expect(info.minLat, closeTo(10.6564, 0.01));
    expect(info.maxLat, closeTo(10.8931, 0.01));
    expect(info.minLon, closeTo(106.5444, 0.01));
    expect(info.maxLon, closeTo(106.8545, 0.01));

    expect(info.contains(10.7865, 106.6656), isTrue); // Cách Mạng Tháng Tám
    expect(info.contains(10.5, 106.4), isFalse); // inside the old fake box
  });

  test('the local multi-zoom build is a different range', () async {
    final info = await NavMapInfo.read(File('tools/data/saigon.pmtiles'));
    if (info == null) return; // build artefact, not tracked
    expect(info.maxZoom, 14);
  });

  test('returns null for a missing or non-pmtiles file', () async {
    expect(
      await NavMapInfo.read(File('assets/offline_map/nope.pmtiles')),
      isNull,
    );
    expect(
      await NavMapInfo.read(File('assets/offline_map/manifest.json')),
      isNull,
    );
  });
}
