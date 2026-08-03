/// Full-screen Vietmap turn-by-turn navigation — their official
/// `NavigationView` SDK + banner + bottom action bar — used when the Vietmap
/// data source is active and online (OSM / offline keep the custom UI).
///
/// The SDK draws the map, the route (with tappable alternatives), the turn
/// banner and the ETA bar itself. We hook `RouteProgressEvent` to keep the
/// BLE e-ink clock and the voice guidance working, and `onMapLongClick` to
/// re-route through a long-pressed point (interactive route editing).
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:vietmap_gl_platform_interface/vietmap_gl_platform_interface.dart'
    as vm; // Vietmap's own LatLng/Point for the SDK calls
import 'package:vietmap_flutter_navigation/models/voice_units.dart'
    show VoiceUnits;
// Hide LatLng: it collides with latlong2, and the SDK calls use
// vietmap_gl_platform_interface's own LatLng (imported as vm above).
import 'package:vietmap_flutter_navigation/vietmap_flutter_navigation.dart'
    hide LatLng;

import 'nav_engine.dart';
import 'nav_protocol.dart';
import 'route_profile.dart';
import 'ui/widgets.dart';
import 'vietmap_config.dart';

class VietmapNavView extends StatefulWidget {
  const VietmapNavView({
    super.key,
    required this.waypoints,
    required this.profile,
    required this.onProgress,
    required this.onArrived,
    required this.onExit,
  });

  /// Origin + stops (2+ points).
  final List<LatLng> waypoints;

  /// Road type (car / motorbike / bicycle / walking).
  final RouteProfile profile;

  /// Called on every progress event with a BLE-ready [NavProgress] + pos.
  final void Function(NavProgress nav, LatLng pos) onProgress;

  /// The SDK reached the destination.
  final VoidCallback onArrived;

  /// Navigation ended / cancelled / user pressed stop.
  final VoidCallback onExit;

  @override
  State<VietmapNavView> createState() => _VietmapNavViewState();
}

class _VietmapNavViewState extends State<VietmapNavView> {
  MapNavigationViewController? _controller;
  MapOptions? _options;
  RouteProgressEvent? _progress;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final plugin = VietMapNavigationPlugin();
    final o = plugin.getDefaultOptions();
    // Keys come from --dart-define (never committed). Without them the SDK
    // asserts, so this widget is only mounted when VietmapConfig.hasKeys.
    o.apiKey = VietmapConfig.apiKey;
    o.mapStyle = VietmapConfig.vectorStyle;
    o.simulateRoute = false; // real GPS (default is true)
    o.units = VoiceUnits.metric; // "200 mét" not miles
    // alternatives/language/'vi'/drivingWithTraffic are already the SDK
    // defaults; long-press is handled below as an interactive re-route.
    plugin.setDefaultOptions(o);
    _options = o;
  }

  DrivingProfile get _profile => switch (widget.profile) {
        RouteProfile.car => DrivingProfile.drivingTraffic,
        RouteProfile.motorbike => DrivingProfile.motorcycle,
        RouteProfile.bicycle => DrivingProfile.cycling,
        RouteProfile.walking => DrivingProfile.walking,
      };

  /// Convert our latlong2 point to the SDK's own LatLng type.
  vm.LatLng _toVm(LatLng p) => vm.LatLng(p.latitude, p.longitude);

  List<vm.LatLng> get _vmWaypoints =>
      [for (final p in widget.waypoints) _toVm(p)];

  /// Build the route and start turn-by-turn once the map is rendered
  /// (the SDK recommends this to avoid crashes while the map draws).
  void _start() {
    final c = _controller;
    if (c == null || _started || widget.waypoints.length < 2) return;
    _started = true;
    c.buildAndStartNavigation(
      waypoints: _vmWaypoints,
      profile: _profile,
    );
  }

  /// Vietmap (Mapbox-style) maneuver strings → our E-ink icon code.
  int _vmIcon(String? type, String? modifier) {
    final t = type ?? '';
    final m = modifier ?? '';
    if (t == 'arrive') return iconArrive;
    if (t.contains('roundabout') || t.contains('rotary')) return iconRoundabout;
    if (m.contains('uturn')) return iconUturnLeft;
    if (m.contains('left')) {
      return m.contains('slight') ? iconSlightLeft : iconTurnLeft;
    }
    if (m.contains('right')) {
      return m.contains('slight') ? iconSlightRight : iconTurnRight;
    }
    return iconStraight;
  }

  void _onProgress(RouteProgressEvent e) {
    if (!mounted) return;
    setState(() => _progress = e);
    final meter = (e.distanceToNextTurn ?? e.distanceRemaining ?? 0).round();
    final remain = (e.durationRemaining ?? 0).round();
    final eta = DateTime.now().add(Duration(seconds: remain));
    final total = (e.distanceRemaining ?? 0) + (e.distanceTraveled ?? 0);
    final loc = e.snappedLocation ?? e.currentLocation;
    final nav = NavProgress(
      meter: meter,
      iconCode: _vmIcon(e.currentModifierType, e.currentModifier),
      etaHour: eta.hour,
      etaMinute: eta.minute,
      text: (e.currentStepInstruction ?? '').isEmpty
          ? 'Tiến lên'
          : e.currentStepInstruction!,
      speedMps:
          ((e.currentLocation?.speed ?? e.snappedLocation?.speed) ?? 0)
              .toDouble(),
      progress:
          total > 0 ? ((e.distanceTraveled ?? 0) / total).clamp(0.0, 1.0) : 0,
    );
    final pos = (loc?.latitude != null && loc?.longitude != null)
        ? LatLng(loc!.latitude!.toDouble(), loc.longitude!.toDouble())
        : widget.waypoints.first;
    widget.onProgress(nav, pos);
  }

  /// Long-press a point on the map → re-route through it (the SDK's
  /// interactive route-editing equivalent of Google's drag-the-line).
  void _onLongClick(vm.LatLng? latLng, dynamic point) {
    final c = _controller;
    if (c == null || latLng == null || widget.waypoints.length < 2) return;
    final w = <vm.LatLng>[
      _toVm(widget.waypoints.first),
      latLng,
      _toVm(widget.waypoints.last),
    ];
    c.buildRoute(waypoints: w, profile: _profile);
    c.startNavigation();
  }

  Widget _instructionIcon() {
    final e = _progress;
    final icon = e == null
        ? Icons.navigation
        : maneuverIcon(_vmIcon(e.currentModifierType, e.currentModifier));
    return Container(
      width: 52,
      height: 52,
      decoration:
          const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: Icon(icon, color: const Color(0xFF1A73E8), size: 28),
    );
  }

  Widget _recenterButton() {
    return Padding(
      padding: const EdgeInsets.only(right: 10, bottom: 4),
      child: FloatingActionButton.small(
        heroTag: 'vm_recenter',
        backgroundColor: Colors.white,
        onPressed: () => _controller?.recenter(),
        child: const Icon(Icons.my_location, color: Color(0xFF1A73E8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    if (o == null) return const ColoredBox(color: Color(0xFFE8EAED));
    return Stack(
      children: [
        Positioned.fill(
          child: NavigationView(
            mapOptions: o,
            onMapCreated: (c) => _controller = c,
            onMapRendered: _start,
            onRouteProgressChange: _onProgress,
            onArrival: widget.onArrived,
            onNavigationCancelled: () => widget.onExit(),
            onNavigationFinished: () => widget.onExit(),
            onNewRouteSelected: (_) {
              // The SDK already switched the route; the progress stream
              // keeps feeding the clock + voice.
            },
            onMapLongClick: _onLongClick,
          ),
        ),
        // Their ready-made banner (top) + ETA/stop bar (bottom).
        SafeArea(
          child: Column(
            children: [
              BannerInstructionView(
                routeProgressEvent: _progress,
                instructionIcon: _instructionIcon(),
              ),
              const Spacer(),
              BottomActionView(
                controller: _controller,
                routeProgressEvent: _progress,
                recenterButton: _recenterButton(),
                onStopNavigationCallback: () => widget.onExit(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller?.onDispose();
    super.dispose();
  }
}
