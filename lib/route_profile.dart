/// Route / road type (vehicle profile) used when planning a route.
library;

import 'package:flutter/material.dart';

enum RouteProfile { car, motorbike, bicycle, walking }

/// The four selectable profiles (in cycle order).
const List<RouteProfile> kRouteProfiles = [
  RouteProfile.car,
  RouteProfile.motorbike,
  RouteProfile.bicycle,
  RouteProfile.walking,
];

extension RouteProfileX on RouteProfile {
  String get label => switch (this) {
        RouteProfile.car => 'Ô tô',
        RouteProfile.motorbike => 'Xe máy',
        RouteProfile.bicycle => 'Xe đạp',
        RouteProfile.walking => 'Đi bộ',
      };

  IconData get icon => switch (this) {
        RouteProfile.car => Icons.directions_car,
        RouteProfile.motorbike => Icons.two_wheeler,
        RouteProfile.bicycle => Icons.directions_bike,
        RouteProfile.walking => Icons.directions_walk,
      };

  /// OSRM profile name. The public OSRM server offers driving/cycling/walking;
  /// motorbikes ride on the car network → driving.
  String get osrm => switch (this) {
        RouteProfile.car || RouteProfile.motorbike => 'driving',
        RouteProfile.bicycle => 'cycling',
        RouteProfile.walking => 'walking',
      };

  RouteProfile get next => switch (this) {
        RouteProfile.car => RouteProfile.motorbike,
        RouteProfile.motorbike => RouteProfile.bicycle,
        RouteProfile.bicycle => RouteProfile.walking,
        RouteProfile.walking => RouteProfile.car,
      };
}
