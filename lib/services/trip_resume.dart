/// The journey a driver turned OFF, kept in the shape the planner needs to
/// pick it up again.
///
/// Turning navigation off throws the route, the engine and the destination
/// away, so "stop, then carry on to the same place" used to mean searching the
/// destination again. What survives here is only what the planner cannot
/// re-derive: where the driver was going, the stop order and the routing
/// choices. The route itself is deliberately NOT kept — it has to be re-planned
/// from where the car is NOW, since the old geometry starts where the old drive
/// started.
library;

import 'package:latlong2/latlong.dart';

import '../core/route_profile.dart';
import '../core/trip_plan.dart';

class TripResume {
  const TripResume({
    required this.stops,
    required this.profile,
    required this.avoidHighway,
    required this.avoidFerry,
    required this.preference,
  });

  /// Stops in the order the driver planned them; the LAST one is the
  /// destination the offer names.
  final List<TripStop> stops;
  final RouteProfile profile;
  final bool avoidHighway;
  final bool avoidFerry;
  final RoutePreference preference;

  LatLng get destination => stops.last.pos;

  /// What the offer shows: the destination's name, or a neutral label for a
  /// stop that was never named.
  String get label {
    final n = stops.last.name.trim();
    return n.isEmpty ? 'Điểm đến' : n;
  }

  /// Capture a run, or null when there is nothing to come back to.
  ///
  /// [wasNavigating]: only a run that actually navigated is resumable. The same
  /// exit routine also clears a merely PLANNED route ("Xoá lộ trình"), and
  /// re-offering a journey the driver just deleted is wrong.
  ///
  /// [arrived]: reaching the destination ends the journey.
  ///
  /// The stops are copied, so later edits to the page's live list cannot
  /// rewrite what the offer promises.
  static TripResume? capture({
    required List<TripStop> stops,
    required RouteProfile profile,
    required bool avoidHighway,
    required bool avoidFerry,
    required RoutePreference preference,
    required bool wasNavigating,
    required bool arrived,
  }) {
    if (!wasNavigating || arrived || stops.isEmpty) return null;
    return TripResume(
      stops: List<TripStop>.unmodifiable(stops),
      profile: profile,
      avoidHighway: avoidHighway,
      avoidFerry: avoidFerry,
      preference: preference,
    );
  }
}
