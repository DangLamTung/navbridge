/// Nav camera / sign-marker math, kept out of the map widget so it is testable
/// without a MapLibre viewport (test/nav_layout_math_test.dart).
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Ease [current] degrees toward [target] by [dtS] seconds — shortest way round
/// the 0/360 wrap. [tau] ≈ time constant (0.25 s ≈ a 90° turn in half a second).
double easeBearingDeg(
  double current,
  double target,
  double dtS, {
  double tau = 0.25,
}) {
  if (dtS.isNaN || dtS <= 0 || dtS > 1.0 || tau <= 0) return target;
  final d = (target - current + 540) % 360 - 180;
  final k = 1 - math.exp(-dtS / tau);
  return (current + d * k + 360) % 360;
}

/// Screen-space unit vector to the RIGHT of the direction of travel, for a
/// camera facing [cameraBearingDeg] (0 = north-up). Screen +y is DOWN, so
/// heading-up gives (1, 0); north-up rotates it with the map.
Offset rightOfTravel({
  required double roadBearingDeg,
  required double cameraBearingDeg,
}) {
  if (roadBearingDeg <= 0 ||
      roadBearingDeg.isNaN ||
      !roadBearingDeg.isFinite) {
    return const Offset(1, 0); // unknown heading: fall back to screen-right
  }
  final a = (roadBearingDeg - cameraBearingDeg) * math.pi / 180.0;
  return Offset(math.cos(a), math.sin(a));
}

/// Park each sign marker [sidePx] right of the travel direction (a 40 px icon
/// on the road coordinate hides the street), and step any marker landing within
/// [clusterPx] of one already placed to the next slot — right, left, further
/// right … so a junction's signs straddle the road instead of stacking up.
/// Slots on one side sit [stackPx] apart. Same order as [points].
List<Offset> spreadSignMarkers(
  List<Offset> points, {
  required double roadBearingDeg,
  required double cameraBearingDeg,
  double sidePx = 24,
  double stackPx = 56,
  double clusterPx = 44,
  int maxStack = 6,
}) {
  final right = rightOfTravel(
    roadBearingDeg: roadBearingDeg,
    cameraBearingDeg: cameraBearingDeg,
  );
  Offset slot(Offset p, int k) {
    // k 0 = right, 1 = left, 2 = further right, 3 = further left, …
    final side = k.isOdd ? -1.0 : 1.0;
    return p + right * (side * (sidePx + (k ~/ 2) * stackPx));
  }

  final out = <Offset>[];
  for (final p in points) {
    var k = 0;
    var placed = slot(p, k);
    while (k < maxStack && out.any((q) => (q - placed).distance < clusterPx)) {
      k++;
      placed = slot(p, k);
    }
    out.add(placed);
  }
  return out;
}
