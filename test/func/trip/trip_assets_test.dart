import 'package:flutter_test/flutter_test.dart';
import 'package:navbridge/services/trip_replay.dart';

/// The drives BUNDLED in the app: a staged-but-undeclared asset (or a name
/// mangled on disk) would give the picker an entry that cannot load.
void main() {
  // rootBundle needs a binding (same as the other asset-backed tests).
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled catalogue lists trips with asset-key refs', () async {
    final trips = await TripReplay.servedTrips();
    if (trips.isEmpty) {
      // A checkout that has not staged anything (CI stubs the big assets) is
      // not a failure here — the console just falls back to its path box.
      markTestSkipped('no assets/trips/index.json — run '
          'tool/sim_trips.py --asset');
      return;
    }
    for (final t in trips) {
      expect(t.name, isNotEmpty);
      expect(t.ref, startsWith('assets/trips/'));
      expect(t.ref, endsWith('.json'));
      // Flutter URI-encodes non-ASCII asset keys, so a ref with non-ASCII
      // characters is a dead entry in the picker (see tool/sim_trips.py
      // asset_name).
      expect(
        t.ref,
        matches(RegExp(r'^[\x20-\x7e]+$')),
        reason: '${t.ref} is not an ASCII asset key',
      );
      expect(t.km, greaterThan(0), reason: '${t.ref} has no length recorded');
    }
  });

  test('every listed trip loads and carries fixes', () async {
    final trips = await TripReplay.servedTrips();
    for (final t in trips) {
      final fixes = await TripReplay.load(t.ref);
      expect(fixes.length, greaterThan(10), reason: '${t.ref} loaded no track');
      // A track with no time stamps would replay as an instant jump.
      expect(
        fixes.last.at.isAfter(fixes.first.at),
        isTrue,
        reason: '${t.ref} has no usable time range',
      );
    }
  });
}
