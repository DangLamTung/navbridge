// TEMPORARY SWEEP: run the app's own posted-limit chain over EVERY fix of the
// HN-SG (QL1A) fixture and dump the verdicts, so the audit map can show the
// whole 1 690 km instead of three short replay windows.
//
// The web harness can only sample (a replay at 4x feeds ~4 fixes/s and the page
// diagnostic is throttled 1-in-50); the chain itself is offline and O(1) per
// fix, so sweeping it here gives full coverage in seconds.
//
//   flutter test tool/experiments/_limit_sweep_test.dart
//   -> docs/hn_sg_limit_sweep.json   [lat, lng, limit, source, street]
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';

const _trip = 'build/web/trips/hn_sg.json';
const _out = 'docs/hn_sg_limit_sweep.json';
const _stride = 4; // every 4th fix ≈ 1 per 80 m — denser than any map needs

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sweep the limit chain over every fix of the QL1A trip', () async {
    final file = File(_trip);
    if (!file.existsSync()) {
      markTestSkipped('$_trip missing (build the web trips first)');
      return;
    }
    await loadOfflineSpeedLimits();
    if (!speedLimitsPopulated) {
      markTestSkipped('speed-limit assets are stubs here (tool/stub_assets.sh)');
      return;
    }

    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final locs = (doc['locations'] as List).cast<Map<String, dynamic>>();

    final rows = <List<Object?>>[];
    final counts = <String, int>{};
    // Mirror the page: it asks the chain to KEEP the value already on screen
    // while two parallel records of the same road disagree (keepKmh),
    // otherwise the chip swaps 60/50 with GPS noise.
    int? keep;
    final w = Stopwatch()..start();
    for (var i = 0; i < locs.length; i += _stride) {
      final f = locs[i];
      final lat = (f['latitudeE7'] as num) / 1e7;
      final lng = (f['longitudeE7'] as num) / 1e7;
      // The seam: pass the fix's OWN heading. Without it the layer's
      // per-direction values (fwd != rev on a dual carriageway / ramp) are
      // picked arbitrarily, which shows up as phantom limit flips.
      final head = (f['heading'] as num?)?.toDouble();
      final hit = await lookupSpeedLimit(LatLng(lat, lng),
          headingDeg: head, keepKmh: keep);
      if (hit != null && hit.limit > 0) keep = hit.limit;
      final src = hit?.source ?? 'none';
      counts[src] = (counts[src] ?? 0) + 1;
      rows.add([
        double.parse(lat.toStringAsFixed(5)),
        double.parse(lng.toStringAsFixed(5)),
        hit?.limit ?? 0,
        src,
        hit?.streetName ?? '',
      ]);
    }
    w.stop();

    File(_out).writeAsStringSync(jsonEncode(rows));
    final n = rows.length;
    // ignore: avoid_print
    print(
      'swept $n fixes of ${locs.length} in ${w.elapsedMilliseconds}ms → $_out',
    );
    for (final e in counts.entries) {
      // ignore: avoid_print
      print(
        '  ${e.key.padRight(9)} ${e.value.toString().padLeft(6)} '
        '${(100.0 * e.value / n).toStringAsFixed(1)}%',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
