/// Short badge label naming WHERE a displayed speed limit came from.
///
/// One implementation for both surfaces: the app's dial/chip
/// (`navigation_page._limitSourceLabel`) and the standalone floating overlay.
/// They used to map the same `RoadInfo.src` values through two different
/// switches, so a new/renamed source could surface as 'CLASS' in one place and
/// 'WAZE' in the other — the badge is what the driver uses to judge the number,
/// so it must not differ between the two.
library;

import 'package:navbridge/services/overpass.dart';

/// 'SIGN' when a posted sign is in force, else the layer behind the road value:
/// WAZE (segment), WAZE pt (Waze posted-limit point), VIETMAP (E-DOG point),
/// OSM (`maxspeed` tag), CITY (built-up rule), CLASS (statutory default).
String limitSourceLabel(String? src, {bool sign = false}) {
  if (sign) return 'SIGN';
  return switch (src) {
    srcSegment => 'WAZE',
    srcWazePoint => 'WAZE pt',
    srcVietmap => 'VIETMAP',
    srcOsm => 'OSM',
    srcCity => 'CITY',
    _ => 'CLASS',
  };
}
