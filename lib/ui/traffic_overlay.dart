/// Turning [RouteTraffic] into drawable pieces for the map layers.
///
/// Pure so the slicing can be tested without a map: a span is an index RANGE
/// into the route geometry (Google's convention, `end` exclusive), and both
/// renderers only ever need `(points, colour)`.
library;

import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/route_traffic.dart';

/// One jam run ready to paint.
class TrafficPolyline {
  const TrafficPolyline({required this.points, required this.level});

  final List<LatLng> points;
  final TrafficLevel level;

  /// Amber for slow, red for a jam — the two colours every driver reads without
  /// a legend (Google/Waze use the same ramp).
  Color get color => switch (level) {
    TrafficLevel.jam => const Color(0xFFD32F2F),
    TrafficLevel.slow => const Color(0xFFF9A825),
    TrafficLevel.normal => const Color(0xFF34A853),
  };
}

/// The jam runs of [route] as drawable polylines.
///
/// Runs shorter than [minPoints] vertices are dropped: a two-vertex stub on a
/// long route is invisible on screen and only costs a draw call. Adjacent runs
/// are NOT merged — Google already returns them merged, and the seam between a
/// `slow` and a `jam` run must stay visible.
List<TrafficPolyline> trafficRouteSpans(OsrmRoute? route, {int minPoints = 2}) {
  final t = route?.traffic;
  if (t == null || !t.hasJams || route!.geometry.length < 2) {
    return const [];
  }
  final geo = route.geometry;
  final out = <TrafficPolyline>[];
  for (final s in t.jams) {
    final a = s.start.clamp(0, geo.length - 1);
    // `end` is exclusive, but the last point must be included so consecutive
    // runs join without a gap: slice to end (clamped) inclusive.
    final b = s.end.clamp(a + 1, geo.length);
    if (b - a < minPoints) continue;
    out.add(TrafficPolyline(points: geo.sublist(a, b), level: s.level));
  }
  return out;
}
