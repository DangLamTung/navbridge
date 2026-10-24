/// The built-up zone at the START of a drive may only be seeded from a boundary
/// sign the driver is about to reach. Beyond that the sign describes a different
/// place, and owning the flag with it made the whole drive wrong (user,
/// 2026-10-24: "sai cái vụ ra vào khu dân cư").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/urban_area.dart';

void main() {
  test('a nearby boundary describes the zone we are in NOW', () {
    // "Hết khu dân cư" 300 m ahead ⇒ we are still inside.
    expect(townSeedFromBoundary(isEndSign: true, aheadM: 300), isTrue);
    // "Bắt đầu khu dân cư" 300 m ahead ⇒ we are still outside.
    expect(townSeedFromBoundary(isEndSign: false, aheadM: 300), isFalse);
  });

  test('a distant boundary says nothing about the zone under the wheels', () {
    // A different town 25 km down a rural leg: this used to declare the driver
    // "outside town" for the rest of the drive, overriding the density probe.
    expect(townSeedFromBoundary(isEndSign: true, aheadM: 25000), isNull);
    expect(townSeedFromBoundary(isEndSign: false, aheadM: 25000), isNull);
    // Just past the window, still nothing.
    expect(townSeedFromBoundary(isEndSign: true, aheadM: 2000), isNull);
  });

  test('the window edge is inclusive and a passed sign is not a seed', () {
    expect(
      townSeedFromBoundary(isEndSign: true, aheadM: kTownSeedAheadM),
      isTrue,
    );
    expect(townSeedFromBoundary(isEndSign: true, aheadM: -10), isNull);
  });
}
