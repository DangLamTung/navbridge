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
}

/// Route preference / routing style used when planning a route.
enum RoutePreference { fastest, shortest, mainRoads, scenic }

/// The four selectable preferences (in cycle order).
const List<RoutePreference> kRoutePreferences = [
  RoutePreference.fastest,
  RoutePreference.shortest,
  RoutePreference.mainRoads,
  RoutePreference.scenic,
];

extension RoutePreferenceX on RoutePreference {
  String get label => switch (this) {
    RoutePreference.fastest => 'Nhanh nhất',
    RoutePreference.shortest => 'Ngắn nhất',
    RoutePreference.mainRoads => 'Đường chính',
    RoutePreference.scenic => 'Đẹp cảnh',
  };

  String get hint => switch (this) {
    RoutePreference.fastest => 'Ưu tiên thời gian',
    RoutePreference.shortest => 'Ưu tiên khoảng cách',
    RoutePreference.mainRoads => 'Ưu tiên đường lớn',
    RoutePreference.scenic => 'Ưu tiên cảnh đẹp',
  };

  IconData get icon => switch (this) {
    RoutePreference.fastest => Icons.speed,
    RoutePreference.shortest => Icons.straighten,
    RoutePreference.mainRoads => Icons.route,
    RoutePreference.scenic => Icons.landscape,
  };
}
