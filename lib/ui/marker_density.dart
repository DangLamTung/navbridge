/// How many map markers (signs / cameras) may be drawn at a given zoom.
///
/// Every marker is a Flutter widget reprojected on the camera ticker (throttled
/// to ~4 Hz), so an unbounded layer is exactly what makes the low-end phone
/// stutter. Density should therefore follow the zoom — at street level the
/// driver wants every sign on the route, at region scale almost none — and each
/// layer needs a HARD ceiling that the zoom can never push through.
///
/// Pure function so the curve can be unit-tested without a map.
library;

/// Markers to draw at [zoom], interpolated between [atMin] (at [minZoom] and
/// below) and [atMax] (at [maxZoom] and above).
///
/// [maxZoom] defaults to 18 because the nav camera tops out at z19 and the
/// detail beyond z18 is already maxed out; [hardCap] is the absolute ceiling for
/// the layer, applied even if [atMax] is raised later.
int markerCapForZoom(
  double zoom, {
  required int atMin,
  required int atMax,
  double minZoom = 13,
  double maxZoom = 18,
  int? hardCap,
}) {
  final cap = hardCap ?? atMax;
  if (zoom.isNaN) return atMin;
  if (zoom <= minZoom) return atMin.clamp(0, cap);
  if (zoom >= maxZoom) return atMax.clamp(0, cap);
  final t = (zoom - minZoom) / (maxZoom - minZoom);
  return (atMin + (atMax - atMin) * t).round().clamp(0, cap);
}

/// Signs per frame on the nav map — few at region scale, all of the route at
/// street level, never more than [kMaxSignMarkers].
int signMarkerCap(double zoom) => markerCapForZoom(
  zoom,
  atMin: 12,
  atMax: kMaxSignMarkers,
  minZoom: 13,
  maxZoom: 17,
  hardCap: kMaxSignMarkers,
);

/// Cameras per frame — cameras cluster far less than signs, so a slightly
/// smaller floor, same ceiling.
int cameraMarkerCap(double zoom) => markerCapForZoom(
  zoom,
  atMin: 10,
  atMax: kMaxCameraMarkers,
  minZoom: 13,
  maxZoom: 17,
  hardCap: kMaxCameraMarkers,
);

/// Hard ceilings (a long route can carry a lot of both).
const int kMaxSignMarkers = 60;
const int kMaxCameraMarkers = 60;
