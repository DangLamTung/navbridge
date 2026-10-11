// PROBE (temporary, not part of the gate — see tool/check.sh): print the whole
// built-up / road-form speed matrix the app ACTUALLY serves, so the question
// "is the speed limit correct?" is answered by the code's own output instead of
// by reading the table and hoping.
//
// Run: flutter test tool/experiments/_builtup_matrix_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/urban_area.dart';

void p(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('form matrix — what the app serves for each vehicle', () {
    for (final v in ['motorbike', 'car', 'truck']) {
      p('=== $v');
      p('  IN town  hai chiều : urbanLimit=${urbanLimit(vehicle: v)}  '
          'ceiling=${vehicleCeiling(v, urban: true)}');
      p('  IN town  đường đôi: urbanLimit=${urbanLimit(vehicle: v, divided: true)}  '
          'ceiling=${vehicleCeiling(v, urban: true, divided: true)}');
      p('  rural    hai chiều: ceiling=${vehicleCeiling(v)}');
      p('  rural    đường đôi: ceiling=${vehicleCeiling(v, divided: true)}');
      p('  rural    oneway>=2 làn: '
          'ceiling=${vehicleCeiling(v, oneway: true, lanes: 2)}');
    }
  });

  test('the suspect row — rural DIVIDED, class default vs Thông tư 38', () {
    // TT38/2024 ô tô ngoài khu đông dân cư: đường đôi 90, hai chiều 80.
    // The car table only encodes the two-way number, and `urban == false`
    // never consults the form, so a divided rural primary may read 80.
    for (final cls in ['trunk', 'primary', 'secondary']) {
      p('  car  $cls  rural two-way = ${statutoryLimit(cls, vehicle: 'car')}   '
          'rural divided = ${statutoryLimit(cls, vehicle: 'car', divided: true)}');
    }
  });

  test('real pack — what a driver actually sees in and out of town', () async {
    await loadOfflineSpeedLimits();
    // A town centre and an open-country point, both on a trunk road.
    const points = <String, LatLng>{
      'Hà Nội — Nguyễn Trãi (QL6, in town)': LatLng(20.9950, 105.8100),
      'open country — QL1A, Hà Nam (rural)': LatLng(20.5600, 105.9200),
    };
    for (final e in points.entries) {
      final builtUp = await isUrbanArea(e.value);
      // What the POSTED layer says (no vehicle argument — it is the raw
      // segment/point cascade), and what an UNTAGGED road would then serve.
      final r = await lookupSpeedLimit(e.value);
      p('  ${e.key}');
      final poi = await poiDensity(e.value);
      final seg = await segmentDensity(e.value);
      p('    urban=$builtUp  poidensity=$poi  segdensity=$seg');
      p('    posted layer → ${r == null ? 'nothing' : '${r.limit} via ${r.source} "${r.streetName}"'}');
      for (final v in ['motorbike', 'car']) {
        final untagged = roadInfoFromRoad(
          name: 'probe',
          highway: 'primary',
          vehicle: v,
          urban: builtUp,
        );
        p('    if untagged, 2-way primary: $v → ${untagged.speedLimit} '
            'via ${untagged.src}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
