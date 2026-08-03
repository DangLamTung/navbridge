/// OpenStreetMap turn-by-turn navigation mirrored to the E-ink clock over BLE.
///
/// This page owns the app state (GPS, search, routing, BLE) and composes the
/// map with the small UI widgets in `ui/`. Each widget file is self-contained:
///
///   - [SearchPill]            top search bar
///   - [SuggestionList]        Nominatim results
///   - [MapControls]           zoom +/− and locate buttons
///   - [ClockButton]           E-ink bluetooth connection state
///   - [RoutePreviewCard]      "route ready" bottom card
///   - [NavigationCard]        live turn-by-turn bottom card
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'ble_clock.dart';
import 'device_picker.dart';
import 'nav_engine.dart';
import 'nav_protocol.dart';
import 'offline_screen.dart';
import 'offline_router.dart';
import 'offline_tiles.dart';
import 'osm_api.dart';
import 'osrm.dart';
import 'overpass.dart';
import 'trip_logger.dart';
import 'trip_plan.dart';
import 'trips_screen.dart';
import 'ui/clock_button.dart';
import 'ui/map_controls.dart';
import 'ui/nav_top_bar.dart';
import 'ui/navigation_card.dart';
import 'ui/road_info_chip.dart';
import 'ui/route_preview_card.dart';
import 'ui/search_pill.dart';
import 'ui/stops_panel.dart';
import 'ui/suggestions_list.dart';
import 'ui/widgets.dart';

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});

  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  final MapController _map = MapController();
  final BleClock _clock = BleClock();

  // --- search -----------------------------------------------------------
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<OsmSuggestion> _suggestions = [];
  Timer? _debounce;
  bool _searching = false;
  bool _building = false;

  // --- routing / navigation ---------------------------------------------
  OsrmRoute? _route;
  TurnByTurnEngine? _engine;
  LatLng? _origin;
  LatLng? _destination;
  LatLng? _current;
  NavProgress? _progress;
  StreamSubscription<Position>? _gpsSub;
  bool _navigating = false;
  String _clockStatus = 'off';

  // --- simulated drive (test mode) ---
  Timer? _simTimer;
  bool _simulating = false;
  double _simDist = 0;

  // --- road info (Overpass) ---
  RoadInfo? _roadInfo;
  bool _roadLoading = false;
  DateTime? _lastRoadQuery;

  // --- trip logging (Google Takeout) ---
  TripLogger? _trip;

  // --- offline mode ---
  final OfflineTileProvider _tileProvider = OfflineTileProvider();
  bool _offline = false;
  StreamSubscription<bool>? _connSub;

  // --- multi-stop plan ---
  final List<TripStop> _stops = [];

  @override
  void initState() {
    super.initState();
    _clock.linkStream.listen((l) {
      if (!mounted) return;
      setState(() {
        _clockStatus = switch (l) {
          ClockLink.connected => 'connected',
          ClockLink.connecting => 'connecting',
          ClockLink.off => 'off',
        };
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestPermission();
      _startGps();
      // Load the on-device routing graph if one is already downloaded.
      if (await routingGraphPresent()) {
        final ok = await OfflineRouter.instance.load(await routingGraphPath());
        debugPrint('ROUTER: on-device graph loaded=$ok');
      }
    });
    _connSub = onlineStream().listen((online) {
      if (!mounted) return;
      setState(() => _offline = !online);
    });
    isOnline().then((on) {
      if (mounted) setState(() => _offline = !on);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _gpsSub?.cancel();
    _simTimer?.cancel();
    _connSub?.cancel();
    // If a trip is still recording when the page is closed, save it.
    final t = _trip;
    if (t != null && t.hasEnoughData) {
      unawaited(saveTrip(t).then((_) {}, onError: (Object _) {}));
    }
    _clock.dispose();
    _map.dispose();
    super.dispose();
  }

  // ---- GPS -------------------------------------------------------------

  Future<void> _requestPermission() async {
    final p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();
    }
  }

  void _startGps() {
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((p) {
      final pos = LatLng(p.latitude, p.longitude);
      _current = pos;
      if (_engine == null || !_navigating) return;
      // Off the route? Re-route to the destination (re-navigation).
      if (_engine!.offRouteDistance(pos) > 45) {
        _reRoute(pos);
        return;
      }
      _handleNav(pos, speedMps: p.speed);
    });
  }

  /// Shared by real GPS and the simulated drive: snap, update the card,
  /// push to the clock and keep the camera on the car.
  void _handleNav(LatLng pos, {required double speedMps}) {
    final nav = _engine!.update(pos, speedMps: speedMps);
    _progress = nav;
    debugPrint('SIM: handleNav dist=$_simDist meter=${nav.meter} icon=${nav.iconCode}');
    _sendToClock(nav);
    _refreshRoad(pos);
    _logFix(pos, speedMps);
    _map.move(pos, 17);
    if (mounted) setState(() {});
  }

  /// Look up the current road (type + speed limit) from OSM, throttled to
  /// one network query every 8 s (Overpass limit ~1 req/s).
  Future<void> _refreshRoad(LatLng pos) async {
    if (_roadLoading) return;
    final now = DateTime.now();
    final last = _lastRoadQuery;
    if (last != null && now.difference(last) < const Duration(seconds: 8)) {
      return;
    }
    _lastRoadQuery = now;
    setState(() => _roadLoading = true);
    try {
      final r = await fetchRoadInfo(pos);
      if (!mounted) return;
      setState(() => _roadInfo = r);
    } catch (_) {
      // keep the last known road on failure
    } finally {
      if (mounted) setState(() => _roadLoading = false);
    }
  }

  /// Feed the active trip logger (real GPS or simulated fixes).
  void _logFix(LatLng pos, double speedMps) {
    final t = _trip;
    if (t == null) return;
    t.addFix(pos, speedMps: speedMps, source: _simulating ? 'SIM' : 'GPS');
  }

  /// Start recording a trip (no-op if one is already active).
  void _beginTrip() {
    if (_trip != null) return;
    final dest = _searchCtrl.text.trim();
    _trip = TripLogger(name: dest.isEmpty ? 'Chuyến đi' : dest);
    debugPrint('TRIP: started');
    if (mounted) setState(() {});
  }

  /// Stop recording and save the trip to disk (Google Takeout Records.json).
  Future<void> _finishTrip() async {
    final t = _trip;
    if (t == null) return;
    _trip = null;
    if (mounted) setState(() {});
    if (!t.hasEnoughData) {
      debugPrint('TRIP: skipped (only ${t.fixCount} fix)');
      return;
    }
    try {
      final f = await saveTrip(t);
      debugPrint('TRIP: saved ${f.path}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Đã lưu chuyến đi: ${f.uri.pathSegments.last}'),
        ));
      }
    } catch (e) {
      debugPrint('TRIP: save failed $e');
    }
  }

  /// Re-navigation: fetch a fresh route from [from] to the destination.
  Future<void> _reRoute(LatLng from) async {
    debugPrint('SIM: REROUTE from=$from');
    final dest = _destination;
    if (dest == null) return;
    try {
      final route = await fetchAnyRoute([from, dest]);
      if (!mounted || _destination == null) return;
      setState(() {
        _route = route;
        _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      });
    } catch (_) {
      // keep the old route on failure
    }
  }

  /// Start/stop the simulated drive along the current route.
  void _toggleSimulation() {
    debugPrint('SIM: toggle called, was _simulating=$_simulating');
    if (_simulating) {
      _simTimer?.cancel();
      setState(() => _simulating = false);
      return;
    }
    final engine = _engine;
    if (engine == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hãy chọn địa điểm trước.')),
      );
      return;
    }
    setState(() {
      _navigating = true; // show the nav card
      _simulating = true;
      _simDist = engine.currentCumulative;
    });
    _beginTrip(); // auto-record the (simulated) drive
    // ~8 m per 500 ms ≈ 58 km/h
    debugPrint('SIM: starting timer, simDist=$_simDist');
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final e = _engine;
      if (e == null) return;
      _simDist += 8;
      _handleNav(e.positionAtDistance(_simDist), speedMps: 16);
      if (_simDist % 80 == 0) {
        debugPrint('SIM: tick dist=$_simDist');
      }
    });
  }

  Future<void> _sendToClock(NavProgress nav) async {
    if (!_clock.isConnected) return;
    await _clock.sendNavFrame(
      meter: nav.meter,
      iconCode: nav.iconCode,
      hour: nav.etaHour,
      minute: nav.etaMinute,
      text: nav.text,
    );
  }

  // ---- search (Nominatim → OSRM route) ---------------------------------

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searching = true);
      try {
        final r = await osmAutocomplete(text.trim());
        if (!mounted) return;
        setState(() => _suggestions = r.take(6).toList());
      } catch (_) {
        if (mounted) setState(() => _suggestions = []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _suggestions = []);
  }

  Future<void> _selectSuggestion(OsmSuggestion s) async {
    _searchFocus.unfocus();
    setState(() {
      _suggestions = [];
      _building = true;
      _searchCtrl.text = s.display;
      _stops.add(TripStop(name: s.display, lat: s.lat, lng: s.lng));
      _destination = LatLng(s.lat, s.lng);
      _searchCtrl.clear();
    });
    try {
      await _buildPlanRoute();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không tìm được địa điểm: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  /// Route through all planned stops (origin → stop1 → … → last stop).
  Future<void> _buildPlanRoute() async {
    if (_stops.isEmpty) return;
    final origin = await _resolveOrigin();
    if (origin == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không lấy được vị trí xuất phát.')),
        );
      }
      return;
    }
    _origin = origin;
    _current ??= origin;
    final points = [origin, for (final s in _stops) s.pos];
    final route = await fetchAnyRoute(points);
    debugPrint('PLAN: BUILD ok pts=${points.length} '
        'dist=${route.distance}m stops=${route.stopCumulative.length}');
    if (!mounted) return;
    setState(() {
      _route = route;
      _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      _destination = _stops.last.pos;
      _navigating = false;
      _progress = null;
    });
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(60),
    ));
  }

  List<String> _engineStopNames(OsrmRoute route) =>
      route.stopCumulative.length == _stops.length
          ? [for (final s in _stops) s.name]
          : const [];

  void _moveStop(int index, int delta) {
    final i = index + delta;
    if (i < 0 || i >= _stops.length) return;
    setState(() {
      final s = _stops.removeAt(index);
      _stops.insert(i, s);
    });
    _buildPlanRoute();
  }

  void _removeStop(int index) {
    setState(() => _stops.removeAt(index));
    if (_stops.isEmpty) {
      setState(() {
        _route = null;
        _engine = null;
        _destination = null;
        _progress = null;
      });
      return;
    }
    _buildPlanRoute();
  }

  Future<void> _savePlan() async {
    if (_stops.isEmpty) return;
    final plans = await loadPlans();
    final plan = TripPlan(
      name: _stops.length == 1
          ? _stops.first.name
          : 'Chuyến ${_stops.length} điểm',
      createdAt: DateTime.now(),
      stops: List.of(_stops),
    );
    plans.insert(0, plan);
    await savePlans(plans);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã lưu kế hoạch chuyến đi.')),
      );
    }
  }

  /// Best-effort start position: live fix, last known, or the app default.
  /// Never throws; falls back to the default city (HCMC) when GPS is
  /// unavailable so route planning + simulation still work.
  Future<LatLng?> _resolveOrigin() async {
    final cur = _current;
    if (cur != null) return cur;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LatLng(last.latitude, last.longitude);
    } catch (_) {
      // ignore and try the live fix below
    }
    try {
      final p = await Geolocator.getCurrentPosition();
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return const LatLng(10.8231, 106.6297); // default center (HCMC)
    }
  }

  Future<void> _startNavigation() async {
    debugPrint('SIM: START navigation pressed');
    final engine = _engine;
    if (engine == null) return;
    final origin = await _resolveOrigin();
    if (origin == null) return;
    setState(() => _navigating = true);
    _beginTrip(); // auto-record the real drive
    final nav = engine.update(origin, speedMps: 0);
    _progress = nav;
    _logFix(origin, 0);
    _sendToClock(nav);
    if (mounted) setState(() {});
  }

  Future<void> _exitNavigation() async {
    debugPrint('SIM: EXIT navigation called');
    _simTimer?.cancel();
    setState(() {
      _navigating = false;
      _simulating = false;
      _route = null;
      _engine = null;
      _destination = null;
      _progress = null;
      _roadInfo = null;
      _stops.clear();
    });
    await _finishTrip(); // save the recorded trip
  }

  // ---- BLE clock -------------------------------------------------------

  Future<void> _toggleClock() async {
    if (_clock.isConnected) {
      await _clock.disconnect();
      if (mounted) setState(() => _clockStatus = 'off');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DevicePickerSheet(clock: _clock, onPicked: _connectTo),
    );
  }

  Future<void> _connectTo(String mac) async {
    if (!mounted) return;
    setState(() => _clockStatus = 'connecting');
    try {
      await _clock.connect(mac: mac);
      if (mounted) setState(() => _clockStatus = 'connected');
    } catch (e) {
      if (mounted) {
        setState(() => _clockStatus = 'off');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('BLE: $e')));
      }
    }
  }

  // ---- map helpers -----------------------------------------------------

  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  void _locateMe() {
    final c = _current;
    if (c != null) _map.move(c, 17);
  }

  // ---- trips history ---------------------------------------------------

  String get _destinationName {
    if (_stops.isNotEmpty) return _stops.last.name;
    final t = _searchCtrl.text.trim();
    return t.isEmpty ? 'Điểm đến' : t;
  }

  Future<void> _openTrips() async {
    final plan = await Navigator.of(context).push<TripPlan>(
      MaterialPageRoute(builder: (_) => const TripsScreen()),
    );
    if (plan != null && mounted) {
      setState(() {
        _stops..clear()..addAll(plan.stops);
        _destination = plan.stops.isEmpty ? null : plan.stops.last.pos;
      });
      _buildPlanRoute();
    }
  }

  Future<void> _openOffline() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const OfflineScreen()),
    );
  }

  // ---- UI composition --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final route = _route;
    final current = _current;
    return Scaffold(
      body: Stack(
        children: [
          _buildMap(route, current),
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Pin the top bar to the top — a plain (non-positioned)
                  // child here would be stretched and vertically centered.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _navigating ? _navTopBar() : _topBar(),
                  ),
                  if (_offline)
                    Positioned(
                      top: 58,
                      left: 12,
                      right: 12,
                      child: Material(
                        elevation: 4,
                        shadowColor: Colors.black26,
                        borderRadius: BorderRadius.circular(10),
                        color: const Color(0xFF5F6368),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Row(
                            children: const [
                              Icon(Icons.cloud_off,
                                  size: 16, color: Colors.white),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Đang ngoại tuyến — bản đồ & lộ trình đã tải vẫn hoạt động',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (!_navigating)
                    Positioned(
                      left: 12,
                      right: 66,
                      top: _offline ? 104 : 70,
                      child: _suggestions.isNotEmpty
                          ? SuggestionList(
                              suggestions: _suggestions,
                              onSelected: _selectSuggestion,
                            )
                          : (_stops.isNotEmpty
                              ? StopsPanel(
                                  stops: _stops,
                                  onAdd: () {
                                    _searchCtrl.clear();
                                    _searchFocus.requestFocus();
                                  },
                                  onMoveUp: (i) => _moveStop(i, -1),
                                  onMoveDown: (i) => _moveStop(i, 1),
                                  onRemove: _removeStop,
                                  onSave: _savePlan,
                                )
                              : const SizedBox.shrink()),
                    ),
                  if (_navigating)
                    Positioned(
                      left: 12,
                      top: 74,
                      child: RoadInfoChip(
                        info: _roadInfo,
                        loading: _roadLoading,
                      ),
                    ),
                  Positioned(
                    right: 10,
                    top: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MapControls(
                          onZoomIn: () => _zoomBy(1),
                          onZoomOut: () => _zoomBy(-1),
                          onLocate: _locateMe,
                          hasPosition: current != null,
                        ),
                        const SizedBox(height: 8),
                        RoundActionButton(
                          icon: _simulating ? Icons.stop : Icons.play_arrow,
                          color:
                              _simulating ? Colors.orange : const Color(0xFF34A853),
                          onTap: _toggleSimulation,
                        ),
                        const SizedBox(height: 8),
                        RoundActionButton(
                          icon: Icons.download_for_offline_outlined,
                          color: kAppBlue,
                          onTap: _openOffline,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _bottomArea(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(OsrmRoute? route, LatLng? current) {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: current ?? const LatLng(10.8231, 106.6297),
        initialZoom: 13,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          // Primary = tile.openstreetmap.org with an app-specific User-Agent
          // (see offline_tiles.dart). Requests are throttled to the OSM tile
          // policy and auto-fail over to CARTO/OpenTopoMap on 403/429; OSM
          // "access blocked" placeholder responses are never cached.
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.navbridge.app',
          tileProvider: _tileProvider,
        ),
        if (route != null)
          PolylineLayer(polylines: [
            // white casing under the blue route (Google look)
            Polyline(points: route.geometry, color: Colors.white, strokeWidth: 9),
            Polyline(points: route.geometry, color: kAppBlue, strokeWidth: 6),
          ]),
        MarkerLayer(markers: [
          if (_origin != null)
            Marker(
              point: _origin!,
              width: 30,
              height: 30,
              child: const OriginMarker(),
            ),
          // numbered markers for intermediate stops (the last stop is the
          // red destination pin below)
          for (var i = 0; i < _stops.length - 1; i++)
            Marker(
              point: _stops[i].pos,
              width: 28,
              height: 28,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kAppBlue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Text('${i + 1}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          if (_destination != null)
            Marker(
              point: _destination!,
              width: 44,
              height: 44,
              child: const Icon(
                Icons.location_pin,
                color: Colors.red,
                size: 44,
                shadows: [Shadow(color: Colors.black38, blurRadius: 4)],
              ),
            ),
          if (current != null)
            Marker(
              point: current,
              width: 26,
              height: 26,
              child: const CurrentMarker(),
            ),
        ]),
      ],
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: SearchPill(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              onClear: _clearSearch,
              busy: _searching || _building,
              showClear: _searchCtrl.text.isNotEmpty,
            ),
          ),
          const SizedBox(width: 8),
          ClockButton(status: _clockStatus, onTap: _toggleClock),
          const SizedBox(width: 8),
          RoundActionButton(
            icon: Icons.history,
            color: kAppBlue,
            onTap: _openTrips,
            size: 44,
          ),
        ],
      ),
    );
  }

  /// Compact header shown while navigating (replaces the search bar).
  Widget _navTopBar() {
    final nav = _progress;
    return NavTopBar(
      destination: _destinationName,
      progress: nav,
      recording: _trip != null,
      clockConnected: _clock.isConnected,
      stopLabel: (nav?.totalStops ?? 0) > 1
          ? 'Điểm ${(nav!.stopIndex + 1)}/${nav.totalStops}'
          : '',
      onExit: _exitNavigation,
    );
  }

  Widget _bottomArea() {
    final route = _route;
    final nav = _progress;
    final card = _navigating
        ? NavigationCard(
            progress: _progress,
            onStop: _exitNavigation,
            stopLabel: (nav?.totalStops ?? 0) > 1
                ? 'Điểm ${(nav!.stopIndex + 1)}/${nav.totalStops}'
                : '',
          )
        : (route != null
            ? RoutePreviewCard(
                etaText: '${(route.duration / 60).round()} ph',
                distanceText: formatDistance(route.distance),
                destination: _destinationName,
                stopCount: _stops.length,
                onStart: _startNavigation,
                onClear: _exitNavigation,
              )
            : null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const OsmAttribution(),
        if (card != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: card,
          ),
      ],
    );
  }
}
