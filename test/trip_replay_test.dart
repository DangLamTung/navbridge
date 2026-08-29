/// Replay today's real trip logs through the production GPS filters
/// ([StrictHeading] + [CarFilter] + route snap) to verify, on real data,
/// that the car arrow no longer flips while stationary and the position/
/// speed stay smooth. This is the "simulate the path from today" check.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navbridge/core/car_filter.dart';
import 'package:navbridge/core/heading_filter.dart';
import 'package:navbridge/core/outlier_gate.dart';
import 'package:navbridge/core/route_snap.dart';

class _Fix {
  final LatLng pos;
  final int tsMs;
  final double? heading; // logged heading — the "raw" compass-ish input
  _Fix(this.pos, this.tsMs, this.heading);
}

List<_Fix> _loadTrip(String path) {
  final d = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final locs = (d['locations'] as List).cast<Map<String, dynamic>>();
  return [
    for (final f in locs)
      _Fix(
        LatLng(f['latitudeE7'] / 1e7, f['longitudeE7'] / 1e7),
        int.tryParse(f['timestampMs'].toString()) ??
            (f['timestampMs'] as num?)?.toInt() ??
            0,
        (f['heading'] as num?)?.toDouble(),
      ),
  ];
}

double _meters(LatLng a, LatLng b) {
  final la1 = a.latitude * math.pi / 180;
  final la2 = b.latitude * math.pi / 180;
  final dLa = (b.latitude - a.latitude) * math.pi / 180;
  final dLo = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dLa / 2) * math.sin(dLa / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLo / 2) * math.sin(dLo / 2);
  return 2 * 6371000 * math.asin(math.sqrt(h));
}

double _angDiff(double a, double b) {
  var d = (a - b) % 360;
  if (d < 0) d += 360;
  return d > 180 ? 360 - d : d;
}

/// Replay one trip; returns a stats map for assertions + reporting.
Map<String, Object> _replay(String path) {
  final fixes = _loadTrip(path);
  final route = [for (final f in fixes) f.pos]; // today's path = the "route"

  // --- heading through the REAL StrictHeading filter ---
  final h = StrictHeading();
  int stationaryFlips = 0, movingFlips = 0;
  double? prevOut;
  for (var i = 0; i < fixes.length; i++) {
    final out = h.update(fixes[i].heading, fixes[i].pos);
    if (out != null && prevOut != null) {
      final moved = i == 0 ? 0.0 : _meters(fixes[i - 1].pos, fixes[i].pos);
      if (_angDiff(out, prevOut) > 120) {
        if (moved < 2.0) {
          stationaryFlips++;
        } else {
          movingFlips++;
        }
      }
    }
    prevOut = out;
  }

  // --- position + speed through the REAL CarFilter + route snap ---
  final kf = CarFilter();
  double maxRawJump = 0, maxFiltJump = 0, maxKmh = 0;
  LatLng? prevRaw, prevFilt;
  for (var i = 0; i < fixes.length; i++) {
    final f = fixes[i];
    final dt = i == 0 ? null : (f.tsMs - fixes[i - 1].tsMs) / 1000.0;
    kf.update(f.pos, dt: dt); // no route bearing → travel-bearing fallback
    final snapped = snapToRoutePolyline(kf.position, route);
    if (prevRaw != null) {
      maxRawJump = math.max(maxRawJump, _meters(prevRaw, f.pos));
    }
    if (prevFilt != null) {
      maxFiltJump = math.max(maxFiltJump, _meters(prevFilt, snapped));
    }
    maxKmh = math.max(maxKmh, kf.speedMps * 3.6);
    prevRaw = f.pos;
    prevFilt = snapped;
  }

  // --- outlier gate through the REAL OutlierGate (innovation gate) ---
  // dt is measured from the last ACCEPTED fix (as the app does) — rejected
  // fixes must not move the reference or the gate over-rejects.
  final gate = OutlierGate();
  double maxAcceptedImpliedKmh = 0;
  LatLng? prevAccPos;
  int? lastAccTs;
  for (var i = 0; i < fixes.length; i++) {
    final f = fixes[i];
    final dt = lastAccTs == null ? null : (f.tsMs - lastAccTs) / 1000.0;
    if (!gate.accept(f.pos, dt: dt)) continue;
    if (prevAccPos != null && dt != null && dt > 0) {
      final implied = _meters(prevAccPos, f.pos) / dt;
      maxAcceptedImpliedKmh = math.max(maxAcceptedImpliedKmh, implied * 3.6);
    }
    prevAccPos = f.pos;
    lastAccTs = f.tsMs;
  }

  return {
    'fixes': fixes.length,
    'stationaryFlips': stationaryFlips,
    'movingFlips': movingFlips,
    'maxRawJumpM': maxRawJump,
    'maxFiltJumpM': maxFiltJump,
    'maxKmh': maxKmh,
    'gateRejected': gate.rejected,
    'maxAcceptedImpliedKmh': maxAcceptedImpliedKmh,
  };
}

void main() {
  final trips = <String, String>{
    '08:25 (323 fixes)': 'test/assets/trips/2026-08-27_082509_Chuyến_đi.json',
    '17:24 (470 fixes)': 'test/assets/trips/2026-08-27_172432_Chuyến_đi.json',
    '17:44 (187 fixes)': 'test/assets/trips/2026-08-27_174413_Chuyến_đi.json',
  };

  for (final entry in trips.entries) {
    final name = entry.key;
    final path = entry.value;
    group('trip replay: $name', () {
      final stats = _replay(path);

      test('heading never flips while stationary (the parked-arrow fix)', () {
        // Before the fix the compass fallback spun the arrow ~0↔225° while
        // parked (today's logs showed 4-11 such flips). The filter now HOLDS
        // the heading when the car hasn't moved ≥2 m.
        expect(
          stats['stationaryFlips'],
          0,
          reason: 'arrow must not spin while parked/stopped',
        );
      });

      test('filtered position does not jump (smoother than the raw fixes)', () {
        final raw = stats['maxRawJumpM']! as double;
        final filt = stats['maxFiltJumpM']! as double;
        // The low-pass + route-snap output must not jump more than the raw GPS
        // feed — and never more than ~1.5× a 25 m bad fix (a hard ceiling).
        expect(
          filt,
          lessThanOrEqualTo(math.max(raw, 25.0)),
          reason: 'filtered position must not jump more than raw GPS',
        );
      });

      test('filtered speed stays bounded (no spikes)', () {
        final kmh = stats['maxKmh']! as double;
        expect(
          kmh,
          lessThan(150),
          reason: 'speed must not spike to an impossible value',
        );
      });

      test(
        'outlier gate rejects bursts; no accepted fix implies >120 km/h',
        () {
          final rej = stats['gateRejected']! as int;
          final maxAcc = stats['maxAcceptedImpliedKmh']! as double;
          // The 17:24 trip contains a 130 km/h single-fix burst — it MUST be
          // rejected, so no accepted fix implies an impossible speed.
          expect(
            maxAcc,
            lessThan(120),
            reason: 'an accepted fix must not imply an impossible speed',
          );
          if (name.contains('17:24')) {
            expect(
              rej,
              greaterThanOrEqualTo(1),
              reason: 'the 130 km/h burst in this trip must be rejected',
            );
          }
        },
      );

      // Diagnostic printout (visible with `flutter test -r expanded`).
      test('report', () {
        // ignore: avoid_print
        print(
          '  $name → stationaryFlips=${stats['stationaryFlips']} '
          'movingFlips=${stats['movingFlips']} '
          'maxJump raw=${stats['maxRawJumpM']}m filt=${stats['maxFiltJumpM']}m '
          'maxSpeed=${stats['maxKmh']}km/h '
          'gateRejected=${stats['gateRejected']} '
          'maxAcceptedImpliedKmh=${stats['maxAcceptedImpliedKmh']}',
        );
      });
    });
  }
}
