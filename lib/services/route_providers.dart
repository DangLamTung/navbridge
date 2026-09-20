/// The routing provider chain — the ONE place that decides which backend
/// computes a route, in what order, and which vehicle behaviour each one can
/// actually honour.
///
/// Before this file the order was implicit in a chain of `if`s inside
/// `fetchAnyRoutes`, and the answer to "does this provider respect 'tránh
/// đường cao tốc'?" was only knowable by reading four different clients. Both
/// questions are now answered here, so the settings screen can *show* the same
/// truth the router *obeys*.
///
/// # Order (highest priority first)
///
/// 1. **Google** — when `dataSource == 'google'` and online. Car / bicycle →
///    Directions API (Legacy); motorbike → Routes API v2 `TWO_WHEELER` (the
///    Legacy API has no two-wheeler mode), which is what keeps a motorbike off
///    VN expressways.
/// 2. **Vietmap** — when `dataSource == 'vietmap'` and online, car + motorbike
///    only (VN-native, live congestion).
/// 3. **GraphHopper** — the on-device graph, car only, offline. Used whenever
///    `routingEngine != 'osrm'`.
/// 4. **OSRM** — online last resort (public server or self-hosted), all
///    profiles. Skipped when `forceOffline` (the user demanded no network) or
///    when the engine is pinned to graphhopper.
///
/// Every step FALLS THROUGH to the next when it fails or returns nothing, and
/// each fall-through is announced (see `noteRouteFallback`) instead of being
/// swallowed into the log.
///
/// # Vehicle behaviour per provider
///
/// | provider     | avoid motorway | avoid ferry | alternatives | offline |
/// |--------------|----------------|-------------|--------------|---------|
/// | google       | yes¹           | yes¹        | yes          | no      |
/// | vietmap      | **ignored**    | **ignored** | yes          | no      |
/// | graphhopper  | yes (car)      | yes (car)   | no           | yes     |
/// | osrm         | yes²           | yes         | yes          | no      |
///
/// ¹ `avoid=highways|ferries` on the Legacy API (driving/bicycling) and
///   `routeModifiers.avoidHighways/avoidFerries` on Routes API v2, which the
///   docs scope to `DRIVE` **and `TWO_WHEELER`** — so motorbikes get it too.
/// ² Not on the public `motorcycle` profile: OSRM's `exclude=motorway` is
///   unsupported there, and the profile already bans motorways.
///
/// Vietmap route v4 takes no exclusion parameter, so the "tránh đường cao tốc"
/// toggle is silently ignored on that source — that is a *known* limitation
/// surfaced in the settings UI rather than a bug. (If Vietmap adds one, wire it
/// in `fetchVietmapRoutes` and flip [RouteProviderX.canAvoidHighway].)
library;

import 'package:navbridge/core/route_profile.dart';

import 'offline_tiles.dart' show forceOffline, routingEngine;
import 'vietmap_config.dart' show dataSource;

/// A backend that can compute a route.
enum RouteProvider { google, vietmap, graphhopper, osrm }

extension RouteProviderX on RouteProvider {
  /// Name shown in the UI.
  String get label => switch (this) {
    RouteProvider.google => 'Google',
    RouteProvider.vietmap => 'Vietmap',
    RouteProvider.graphhopper => 'GraphHopper',
    RouteProvider.osrm => 'OSRM',
  };

  /// Whether the provider needs a working internet connection.
  bool get isOnline => this != RouteProvider.graphhopper;

  /// One-line description (vi) for the settings screen.
  String get behaviour => switch (this) {
    RouteProvider.google =>
      'Chuẩn Google, có giao thông. Tránh cao tốc/phà: có.',
    RouteProvider.vietmap =>
      'Việt Nam, có kẹt xe. Tránh cao tốc/phà: KHÔNG (bỏ qua).',
    RouteProvider.graphhopper =>
      'Ngoại tuyến trên máy (chỉ ô tô). Tránh cao tốc/phà: có.',
    RouteProvider.osrm => 'Trực tuyến dự phòng. Tránh cao tốc/phà: có.',
  };

  /// Whether "tránh đường cao tốc" changes anything on [profile].
  ///
  /// Mirrors exactly what the clients send, so the UI cannot promise a
  /// behaviour the request does not carry.
  bool canAvoidHighway(RouteProfile profile) => switch (this) {
    // Legacy `avoid=highways` (driving/bicycling) + v2 routeModifiers
    // (DRIVE/TWO_WHEELER). Walking never uses highways, so nothing is sent.
    RouteProvider.google => profile != RouteProfile.walking,
    RouteProvider.vietmap => false, // no exclusion parameter in route v4
    RouteProvider.graphhopper => profile == RouteProfile.car,
    RouteProvider.osrm => profile != RouteProfile.motorbike,
  };

  /// Whether "tránh phà" changes anything on [profile].
  bool canAvoidFerry(RouteProfile profile) => switch (this) {
    RouteProvider.google => profile != RouteProfile.walking,
    RouteProvider.vietmap => false,
    RouteProvider.graphhopper => profile == RouteProfile.car,
    RouteProvider.osrm => true,
  };
}

/// The providers that will be TRIED, in order, for [profile] given the current
/// `dataSource` / `forceOffline` / `routingEngine` settings.
///
/// This is the single source of the order: `fetchAnyRoutes` walks exactly this
/// list (no separate `if` chain), and the settings screen prints it, so what
/// the user reads is what the router does.
///
/// An empty result means "no source can serve this request" — the caller turns
/// that into the offline error the UI already knows how to explain.
List<RouteProvider> resolveRouteChain(RouteProfile profile) {
  final chain = <RouteProvider>[];
  if (dataSource == 'google' && !forceOffline) {
    chain.add(RouteProvider.google);
  }
  if (dataSource == 'vietmap' &&
      !forceOffline &&
      (profile == RouteProfile.car || profile == RouteProfile.motorbike)) {
    chain.add(RouteProvider.vietmap);
  }
  if (profile == RouteProfile.car && routingEngine != 'osrm') {
    chain.add(RouteProvider.graphhopper);
  }
  if (!forceOffline && routingEngine != 'graphhopper') {
    chain.add(RouteProvider.osrm);
  }
  return chain;
}

/// Human-readable chain for the settings UI, e.g.
/// `Google → GraphHopper → OSRM`, or `Không có nguồn nào` when empty.
String describeRouteChain(RouteProfile profile) {
  final chain = resolveRouteChain(profile);
  if (chain.isEmpty) return 'Không có nguồn nào cho loại xe này';
  return chain.map((p) => p.label).join(' → ');
}
