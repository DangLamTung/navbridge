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
/// OSM (`maxspeed` tag), KDC (built-up rule), CLASS (statutory default).
///
/// The built-up badge used to read 'CITY'. That named a source the law does not
/// have: the speed depends on the khu dân cư zone, and the density probe is only
/// a substitute for the R.420/R.421 plates (user, 2026-10-25: "tốc độ phụ thuộc
/// biển kdc, cái city chỉ là sub set của cái logic kdc"). WAZE still wins
/// whenever the segment layer answers — see [applyPostedLayer].
String limitSourceLabel(String? src, {bool sign = false}) {
  if (sign) return 'SIGN';
  return switch (src) {
    srcSegment => 'WAZE',
    srcWazePoint => 'WAZE pt',
    srcVietmap => 'VIETMAP',
    srcOsm => 'OSM',
    srcCity => 'KDC',
    _ => 'CLASS',
  };
}
