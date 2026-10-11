// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

/// `docs/trips/` is gitignored (.gitignore:86) - the drive corpus only exists on
/// the machine that recorded it, so this verification must SKIP on a clean
/// checkout rather than fail on a missing fixture.
const _tripCorpusNote =
    'docs/trips/ is local-only (gitignored) - no drive corpus here';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('VERIFY 100% of Lũy Bán Bích points return 60 km/h and zero 50 km/h', () async {
    await loadOfflineSpeedLimits();
    expect(speedLimitsPopulated, isTrue);

    final tripFile = File('docs/trips/2026-09-29_172632_Chuyến_đi.json');
    if (!tripFile.existsSync()) {
      markTestSkipped(_tripCorpusNote);
      return;
    }

    final data = jsonDecode(tripFile.readAsStringSync()) as Map<String, dynamic>;
    final locs = (data['locations'] as List).cast<Map<String, dynamic>>();

    final lbbPoints = <Map<String, dynamic>>[];
    for (var i = 0; i < locs.length; i++) {
      final loc = locs[i];
      final street = (loc['street'] ?? '').toString();
      if (street.contains('Lũy Bán Bích') || street.contains('Luy Ban Bich')) {
        lbbPoints.add({'idx': i, ...loc});
      }
    }

    print('Total LBB points in trip: ${lbbPoints.length}');
    expect(lbbPoints.length, greaterThan(100));

    // Now simulate navigation continuity as implemented in nav_gps.dart:
    var currentSpeedLimit = 0;
    var currentLayer = '';
    var currentStreet = '';
    final simSpeeds = <int>[];
    final simDrops = <String>[];

    for (final pt in lbbPoints) {
      final lat = (pt['latitudeE7'] as num) / 1e7;
      final lng = (pt['longitudeE7'] as num) / 1e7;
      final hdg = (pt['heading'] as num?)?.toDouble();
      final idx = pt['idx'];
      final street = (pt['street'] ?? '').toString();

      final lim = await speedLimitAt(
        LatLng(lat, lng),
        headingDeg: hdg,
        expectStreet: street,
      );
      final layer = lastLimitLayer();

      if (lim != null && lim > 0) {
        currentSpeedLimit = lim;
        currentLayer = layer ?? 'segment';
        currentStreet = street;
      } else {
        // Continuity: if same road and already fromLayer with valid limit, keep it!
        // Otherwise fallback to urban statutory (50)
        final same = currentStreet.contains('Lũy Bán Bích') || currentStreet.contains('Luy Ban Bich');
        if (!(currentLayer == 'segment' && same && currentSpeedLimit > 0)) {
          currentSpeedLimit = 50;
          currentLayer = 'city';
        }
      }

      simSpeeds.add(currentSpeedLimit);
      if (currentSpeedLimit != 60) {
        simDrops.add('#$idx at $lat,$lng -> $currentSpeedLimit ($currentLayer)');
      }
    }

    print('Simulated nav speed on all ${lbbPoints.length} LBB points:');
    print('  60 km/h count: ${simSpeeds.where((s) => s == 60).length}');
    print('  Non-60 count: ${simSpeeds.where((s) => s != 60).length}');
    if (simDrops.isNotEmpty) {
      print('  Sim drops:\n    ${simDrops.join("\n    ")}');
    }

    expect(simSpeeds.every((s) => s == 60), isTrue,
        reason: 'During navigation, Lũy Bán Bích must maintain 60 km/h 100% of the time');
  });
}
