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
import 'dart:math' show Point, Random, max;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_clock.dart';
import 'device_picker.dart';
import 'elevation.dart';
import 'nav_engine.dart';
import 'nav_protocol.dart';
import 'offline_screen.dart';
import 'offline_router.dart';
import 'offline_tiles.dart';
import 'poi_search.dart';
import 'route_profile.dart';
import 'settings.dart';
import 'osm_api.dart';
import 'osrm.dart';
import 'overpass.dart';
import 'trip_logger.dart';
import 'trip_plan.dart';
import 'trips_screen.dart';
import 'ui/arrival_card.dart';
import 'vector_nav_map.dart';
import 'vietmap_api.dart';
import 'vietmap_config.dart';
import 'voice_commands.dart';
import 'voice_guide.dart';
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

  /// Once the user declines "go online for this search", don't nag again
  /// for the rest of the session.
  bool _searchOfflineDeclined = false;
  List<OsmSuggestion> _suggestions = [];
  Timer? _debounce;
  bool _searching = false;
  bool _building = false;

  // --- routing / navigation ---------------------------------------------
  OsrmRoute? _route;
  TurnByTurnEngine? _engine;
  LatLng? _origin;
  LatLng? _destination;

  /// Index into the route polyline where the DRAWN route starts — the driven
  /// part is "consumed" (not drawn), Google-Maps style. Updated on every nav
  /// fix from `engine.snappedSegmentIndex`.
  int _routeStartIndex = 0;
  LatLng? _current;
  double? _heading;
  bool _headingUp = true; // rotate map so travel direction points up
  String _carIcon = 'arrow';
  RouteProfile _routeProfile = RouteProfile.car; // road type for routing
  NavProgress? _progress;
  StreamSubscription<Position>? _gpsSub;
  bool _navigating = false;
  String _clockStatus = 'off';

  // --- Google-style extras: step list, alternative routes ----------------
  bool _showSteps = false; // expanded turn-banner step list
  List<OsrmRoute> _alternativeRoutes = []; // Vietmap alternative routes
  int _selectedRoute = 0; // index into [_alternativeRoutes]
  List<LatLng> _planPoints = []; // route points for re-fitting the camera

  // --- draggable route (Google-style grab-the-line to add a via point) ---
  // One handle per route segment (a simple A→B route has exactly one).
  List<LatLng> _dragHandles = [];
  final ValueNotifier<MapCamera?> _camNotifier = ValueNotifier(null);

  // --- route criteria: traffic / elevation / avoid highway / ferry -------
  bool _avoidHighway = false; // re-plan without motorways (OSRM)
  bool _avoidFerry = false; // re-plan without ferries (OSRM)
  ElevationInfo? _elevation; // ascent/descent of the current route
  final Map<String, ElevationInfo> _elevationCache = {};

  // --- nav map: 3D perspective tilt (Google-style) ----------------------
  bool _tilt3d = true; // tilted perspective camera (turn off = flat 2D)

  // --- quick POI search (gas / food / hotel / … during navigation) ------
  List<PoiResult> _pois = [];
  PoiType? _poiType;
  PoiResult? _selectedPoi; // tapped POI — shown on the map until "Đi đến"
  bool _poiBusy = false;

  // --- nav-map camera follow (drives the auto-center button) -------------
  final VectorNavMapController _vmFollow = VectorNavMapController();

  // --- simulated drive (test mode) ---
  Timer? _simTimer;
  bool _simulating = false;
  double _simDist = 0;
  bool _simOffRoute = false; // NAVTEST: drive off-route to exercise re-routing

  // --- road info (Overpass) ---
  RoadInfo? _roadInfo;
  bool _roadLoading = false;
  DateTime? _lastRoadQuery;

  // --- trip logging (Google Takeout) ---
  TripLogger? _trip;

  // --- offline mode ---
  OfflineTileProvider _tileProvider = OfflineTileProvider();
  bool _offline = false;
  StreamSubscription<bool>? _connSub;

  // --- changeable basemap layers ----------------------------------------
  static const Map<String, String> _tileLayers = {
    'osm': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'carto':
        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    'topo': 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    'esri':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'vietmap': VietmapConfig.satelliteTiles,
  };
  static const List<String> _tileLayerNames = [
    'osm',
    'carto',
    'topo',
    'esri',
    'vietmap',
  ];
  String _tileSource = 'osm'; // active basemap layer

  // --- multi-stop plan ---
  final List<TripStop> _stops = [];

  // --- voice: spoken guidance (Bluetooth speaker) + mic commands --------
  final VoiceGuide _voice = VoiceGuide();
  final VoiceCommands _commands = VoiceCommands();
  bool _listening = false;
  bool _voiceOn = true; // spoken turn-by-turn guidance enabled
  bool _spokenFar = false;
  bool _spokenNear = false;
  bool _spokenFinal = false;
  bool _arrivedSpoken = false;
  String? _lastManeuverSig; // icon+road of the maneuver we last announced
  DateTime? _lastReRoute; // cooldown for off-route re-routing

  // --- online GPS road-snapping (OSRM match) + off-route timing ----------
  final List<LatLng> _gpsWindow = []; // rolling trace for /match
  DateTime? _lastGpsMatch; // throttle: match at most every 5 s
  double _lastSpeedMps = 0;
  DateTime? _offRouteSince; // when the car first went >50 m off-route

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
      // Initial camera for the route drag handle (kept fresh by
      // onPositionChanged).
      try {
        _camNotifier.value = _map.camera;
      } catch (_) {}
    });
    _connSub = onlineStream().listen((online) {
      if (!mounted) return;
      setState(() => _offline = !online || forceOffline);
    });
    isOnline().then((on) {
      if (!mounted) return;
      setState(() => _offline = !on || forceOffline);
    });
    // Restore the persisted offline/online mode + data-source choice.
    loadSettings().then((s) {
      if (!mounted) return;
      forceOffline = s.forceOffline;
      dataSource = s.dataSource;
      setState(() => _offline = _offline || forceOffline);
    });
    // Opt-in simulator test harness (see [_maybeRunNavTest]).
    unawaited(_maybeRunNavTest());
    // Voice: spoken turn-by-turn (→ Bluetooth speaker) + mic commands.
    _voice.init();
    _commands.init(
      onStatus: (s) {
        // Speech session ended (final result / silence / error) → release mic.
        if (s == 'done' || s == 'notListening') {
          _listening = false;
          if (mounted) setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _gpsSub?.cancel();
    _simTimer?.cancel();
    _connSub?.cancel();
    _voice.stop();
    _commands.stop();
    // If a trip is still recording when the page is closed, save it.
    final t = _trip;
    if (t != null && t.hasEnoughData) {
      unawaited(saveTrip(t).then((_) {}, onError: (Object _) {}));
    }
    _clock.dispose();
    _map.dispose();
    super.dispose();
  }

  // ---- opt-in simulator test harness -----------------------------------

  /// With `--dart-define=NAVTEST=true` the app auto-builds a route and starts
  /// the SIM drive, so the full turn-by-turn pipeline (voice announcements,
  /// nav UI, clock frames, road info) can be exercised from logcat without UI
  /// taps:
  ///   - `NAVTEST=true`      → Chợ Bến Thành (~10 km) + drives off-route at
  ///                           20 s to exercise re-routing.
  ///   - `NAVTEST_LONG=true` → Hà Nội (~1 600 km) to verify long-distance
  ///                           planning + engine.
  /// Normal builds (no defines) are completely unaffected.
  Future<void> _maybeRunNavTest() async {
    const long = bool.fromEnvironment('NAVTEST_LONG');
    if (!const bool.fromEnvironment('NAVTEST') && !long) return;
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    debugPrint(
      'NAVTEST: building route to ${long ? 'Hà Nội (~1600km)' : 'Chợ Bến Thành'}',
    );
    setState(() {
      dataSource = 'osm'; // public OSRM routing (works from the emulator)
      _stops.add(
        long
            ? TripStop(name: 'Hà Nội', lat: 21.0285, lng: 105.8542)
            : TripStop(name: 'Chợ Bến Thành', lat: 10.7725, lng: 106.6980),
      );
    });
    try {
      await _buildPlanRoute();
    } catch (e) {
      debugPrint('NAVTEST: plan failed: $e');
      return;
    }
    if (!mounted) return;
    _toggleSimulation();
    debugPrint(
      'NAVTEST: SIM drive started (${long ? 'LONG' : 'short + re-route'})',
    );
    if (!long) {
      // 20 s in, drive off-route to exercise the re-route path (expect
      // `SIM: REROUTE` + a fresh `PLAN: BUILD ok`).
      Future<void>.delayed(const Duration(seconds: 20), () {
        if (!mounted || !_simulating) return;
        debugPrint('NAVTEST: going off-route to test re-routing');
        _simOffRoute = true;
      });
    }
  }

  // ---- GPS -------------------------------------------------------------

  Future<void> _requestPermission() async {
    final p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      await Geolocator.requestPermission();
    }
  }

  void _startGps() {
    _gpsSub?.cancel();
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            // Every fix (no distance filter) → the nav UI, voice and the clock
            // update as fast as the sensor reports, instead of every 3 m.
            distanceFilter: 0,
          ),
        ).listen(
          (p) {
            // During the simulated drive the SIM owns the position — the real
            // GPS stream (e.g. a stationary phone sitting at the origin) was
            // overwriting `_current` back to the origin and re-running the
            // engine/OSRM-snap, which made the map keep "returning to start".
            if (_simulating) return;
            final pos = LatLng(p.latitude, p.longitude);
            _current = pos;
            _heading = p.heading.isNaN ? null : p.heading;
            if (_engine == null || !_navigating) return;
            // Keep a short trace for online OSRM /match road-snapping.
            _gpsWindow.add(pos);
            if (_gpsWindow.length > 15) _gpsWindow.removeAt(0);
            _lastSpeedMps = p.speed;
            unawaited(_maybeSnapToRoad());
            // Off the route? Re-route once the car stays off-path (>50 m)
            // for 10 s (or immediately when it's clearly far gone, >250 m).
            final off = _engine!.offRouteDistance(pos);
            if (off > 50) {
              final now = DateTime.now();
              final since = _offRouteSince ??= now;
              if (off > 250 ||
                  now.difference(since) >= const Duration(seconds: 10)) {
                _offRouteSince = null;
                _reRoute(pos, speedMps: p.speed);
                return;
              }
            } else {
              _offRouteSince = null;
            }
            _handleNav(pos, speedMps: p.speed);
          },
          onError: (Object e) {
            debugPrint('GPS: stream error: $e — restarting');
            _restartGps();
          },
          onDone: _restartGps,
        );
  }

  /// Online GPS road-snapping: send the rolling trace to OSRM /match
  /// (throttled to 5 s) to refine the on-route position when online. The
  /// matched point is projected onto the route polyline and only accepted
  /// when it's close — between matches (and fully offline) the always-on
  /// `engine.snapToRoute` projection keeps the car on the road, so the match
  /// never causes the puck to bounce off/on the route (the old flicker).
  Future<void> _maybeSnapToRoad() async {
    if (forceOffline || _gpsWindow.length < 3 || !_navigating) return;
    final now = DateTime.now();
    if (_lastGpsMatch != null &&
        now.difference(_lastGpsMatch!) < const Duration(seconds: 5)) {
      return;
    }
    _lastGpsMatch = now;
    final matched = await fetchAnyMatch(List.of(_gpsWindow));
    if (!mounted || !_navigating || matched == null) return;
    final engine = _engine;
    if (engine == null) return;
    // Only trust the match when it's on/near our route — otherwise it could
    // yank the car onto a parallel road (e.g. after a wrong turn).
    if (engine.offRouteDistance(matched) > 50) return;
    final projected = engine.snapToRoute(matched);
    // Drop a stale result: if the car moved well beyond where the trace was
    // captured while /match was in flight, the next GPS fix re-snaps anyway.
    final cur = _current;
    if (cur != null && distanceMeters(cur, projected) > 30) return;
    _current = projected;
    final nav = engine.update(projected, speedMps: _lastSpeedMps);
    _progress = nav;
    _sendToClock(nav);
    if (mounted) setState(() {});
  }

  /// Restart the GPS stream shortly after it ends/errors — some devices
  /// drop the stream, which would silently freeze both the UI updates and
  /// the off-route re-routing.
  void _restartGps() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _startGps();
    });
  }

  /// Shared by real GPS and the simulated drive: snap, update the card,
  /// push to the clock and keep the camera on the car.
  void _handleNav(LatLng pos, {required double speedMps}) {
    // Off-route re-route uses the RAW fix — a snapped point is always on the
    // route, so it could never trigger. Stays >50 m off-path for 10 s, or
    // re-routes immediately when clearly far gone.
    final off = _engine!.offRouteDistance(pos);
    if (off > 50) {
      final now = DateTime.now();
      final since = _offRouteSince ??= now;
      if (off > 250 || now.difference(since) >= const Duration(seconds: 10)) {
        _offRouteSince = null;
        unawaited(_reRoute(pos, speedMps: speedMps));
        return;
      }
    } else {
      _offRouteSince = null;
    }
    // Project the raw fix onto the route polyline so the car RIDES the road:
    // the puck, the camera bearing and the turn meter all stay stable even
    // when the real GPS fix wanders a few meters off the road (this is what
    // kept the arrow flickering — the raw fix fed the nearest-vertex bearing).
    final snapped = _engine!.snapToRoute(pos);
    _current = snapped; // keep the vector map + POI search on the route
    final nav = _engine!.update(snapped, speedMps: speedMps);
    _progress = nav;
    // Consume the driven part of the route (the map only draws from here on).
    _routeStartIndex = _engine!.snappedSegmentIndex;
    debugPrint(
      'SIM: handleNav dist=$_simDist meter=${nav.meter} icon=${nav.iconCode} '
      'start=$_routeStartIndex',
    );
    // SIM verification aid: show how much the road-snapping corrected the raw
    // (noisy, in NAVTEST) fix back onto the route.
    if (_simulating) {
      debugPrint(
        'NAVTEST: gps raw=${pos.latitude.toStringAsFixed(5)},'
        '${pos.longitude.toStringAsFixed(5)} → '
        'snapped=${snapped.latitude.toStringAsFixed(5)},'
        '${snapped.longitude.toStringAsFixed(5)} '
        'correct=${distanceMeters(pos, snapped).toStringAsFixed(1)}m',
      );
    }
    _sendToClock(nav);
    _maybeSpeakManeuver(nav);
    _refreshRoad(snapped);
    _logFix(pos, speedMps);
    _map.move(snapped, 17);
    if (mounted) setState(() {});
  }

  /// Look up the current road (type + speed limit). Prefers the on-device
  /// GraphHopper graph (instant + offline); falls back to Overpass.
  Future<void> _refreshRoad(LatLng pos) async {
    final now = DateTime.now();
    final last = _lastRoadQuery;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastRoadQuery = now;
    // On-device graph: no network, no server latency.
    if (OfflineRouter.instance.isLoaded) {
      try {
        final r = await _roadInfoFromGraph(pos);
        if (r != null && mounted) {
          setState(() => _roadInfo = r);
          return;
        }
      } catch (_) {
        // fall through to Overpass
      }
    }
    if (_roadLoading) return;
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

  /// Road info straight from the on-device graph (nearest edge), with the
  /// same Vietnamese statutory defaults as the Overpass path.
  Future<RoadInfo?> _roadInfoFromGraph(LatLng pos) async {
    final g = await OfflineRouter.instance.roadInfo(pos);
    if (g == null) return null;
    debugPrint('ROAD: graph highway=${g['highway']} maxspeed=${g['maxspeed']}');
    final highway = (g['highway'] ?? '') as String;
    if (highway.isEmpty) return null;
    final (label, fallback) = classInfo(highway);
    // GraphHopper sends Infinity for `maxspeed=none` — treat any non-finite
    // value as "no tagged limit" and fall back to the statutory class default.
    final msRaw = g['maxspeed'];
    final ms = (msRaw is num && msRaw.isFinite) ? msRaw.toInt() : null;
    return RoadInfo(
      name: (g['name'] ?? '') as String,
      highway: highway,
      maxspeed: ms == null ? null : '$ms',
      label: label,
      speedLimit: ms ?? fallback,
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã lưu chuyến đi: ${f.uri.pathSegments.last}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('TRIP: save failed $e');
    }
  }

  /// Re-navigation: fetch a fresh route from [from] to the destination.
  /// Keeps the current navigation running and snaps straight into the new
  /// route so the UI + clock update immediately.
  Future<void> _reRoute(LatLng from, {double speedMps = 0}) async {
    // Cooldown: don't re-route-spam while GPS is jittery off-route.
    final now = DateTime.now();
    if (_lastReRoute != null &&
        now.difference(_lastReRoute!) < const Duration(seconds: 10)) {
      return;
    }
    _lastReRoute = now;
    debugPrint('SIM: REROUTE from=$from');
    final dest = _destination;
    if (dest == null) return;
    try {
      final route = await fetchAnyRoute(
        [from, dest],
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      if (!mounted || _destination == null) return;
      setState(() {
        _route = route;
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _showSteps = false;
        _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      });
      // Snap straight into the new route (updates distance, icon, clock,
      // voice) instead of waiting for the next GPS fix.
      _handleNav(from, speedMps: speedMps);
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Hãy chọn địa điểm trước.')));
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
      var pos = e.positionAtDistance(_simDist);
      if (_simOffRoute) {
        // Drive ~300 m east of the route — far enough (>250 m) to trigger an
        // immediate off-route re-route so NAVTEST can verify it.
        pos = LatLng(pos.latitude, pos.longitude + 0.004);
      }
      if (const bool.fromEnvironment('NAVTEST')) {
        // Inject realistic GPS error so the road-snapping (`snapToRoute`) is
        // exercised — the raw fix lands a few metres off the road and is
        // pulled back onto the polyline (see the `NAVTEST: gps` log).
        pos = _addGpsNoise(pos);
      }
      _handleNav(pos, speedMps: 16);
      if (_simDist % 80 == 0) {
        debugPrint('SIM: tick dist=$_simDist offRoute=$_simOffRoute');
      }
    });
  }

  /// Inject realistic GPS error (±~12 m) into a SIM fix so road-snapping is
  /// exercised. The error is CROSS-TRACK (perpendicular to the road) — that's
  /// the component the snapping must correct; along-track error just slides
  /// the car forward/back on the road and adds no value. Only used by the
  /// NAVTEST harness (no effect on normal builds).
  LatLng _addGpsNoise(LatLng p) {
    final r = Random();
    final crossMeters = (r.nextDouble() * 2 - 1) * 12.0;
    return _engine!.lateralOffset(p, crossMeters);
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
        var r = await osmAutocomplete(text.trim());
        // Forced-offline + nothing in the offline cache → ask the user
        // whether to go online for this search, instead of silently showing
        // nothing (they want to CHOOSE to go online if needed).
        if (r.isEmpty && forceOffline && !_searchOfflineDeclined) {
          final goOnline = await _confirmGoOnline(
            'Không có kết quả ngoại tuyến cho “${text.trim()}”.',
          );
          if (goOnline) {
            r = await osmAutocomplete(text.trim());
          } else {
            _searchOfflineDeclined = true; // don't nag again this session
          }
        }
        if (!mounted) return;
        setState(() => _suggestions = r.take(6).toList());
      } catch (_) {
        if (mounted) setState(() => _suggestions = []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  /// When forced-offline is active, ask the user whether to go online for an
  /// action that needs the network (search / routing). Accepting lifts the
  /// offline lock for THIS session only — the persisted setting is unchanged,
  /// so a restart goes back to forced offline. Returns true when the action
  /// may proceed online.
  Future<bool> _confirmGoOnline(String reason) async {
    if (!forceOffline) return true; // already online
    final goOnline = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cần kết nối mạng'),
        content: Text(
          '$reason\n\nBạn có muốn bật trực tuyến (tạm thời) không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Ở ngoại tuyến'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Bật trực tuyến'),
          ),
        ],
      ),
    );
    if (goOnline == true) {
      forceOffline = false; // session only — not persisted
      if (mounted) {
        setState(() => _offline = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Đã bật trực tuyến (phiên này)'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
    return goOnline == true;
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _suggestions = []);
  }

  Future<void> _selectSuggestion(OsmSuggestion s) async {
    _searchFocus.unfocus();
    // Vietmap suggestions carry no coordinates — resolve them on selection.
    var lat = s.lat;
    var lng = s.lng;
    if (s.source == 'vietmap' && s.refId.isNotEmpty) {
      final p = await vietmapPlace(s.refId);
      if (p == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không lấy được tọa độ địa điểm.')),
          );
        }
        return;
      }
      lat = p.$1;
      lng = p.$2;
      s = OsmSuggestion(refId: s.refId, display: s.display, lat: lat, lng: lng);
    }
    setState(() {
      _suggestions = [];
      _building = true;
      _searchCtrl.text = s.display;
      _stops.add(TripStop(name: s.display, lat: lat, lng: lng));
      _destination = LatLng(lat, lng);
      _searchCtrl.clear();
    });
    try {
      await _buildPlanRoute();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không tìm được địa điểm: $e')));
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
    OsrmRoute route;
    List<OsrmRoute> alternatives = [];
    try {
      // OSRM / Vietmap can return up to 3 route options (best first).
      final routes = await fetchAnyRoutes(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      route = routes.first;
      alternatives = routes.length > 1 ? routes : [];
    } catch (_) {
      // Offline and no matching offline data → offer to go online instead
      // of just failing (the user wants to choose if needed).
      if (!forceOffline) rethrow;
      final msg = _routeProfile == RouteProfile.car
          ? 'Chưa có bộ dữ liệu chỉ đường ngoại tuyến cho tuyến này.'
          : 'Bộ dữ liệu ngoại tuyến chỉ hỗ trợ ô tô — cần trực tuyến cho ${_routeProfile.label.toLowerCase()}. ';
      final goOnline = await _confirmGoOnline(msg);
      if (!goOnline || !mounted) return;
      route = await fetchOsrmRoute(
        points,
        profile: _routeProfile.osrm,
        exclude: osrmExclude(
          avoidHighway: _avoidHighway,
          avoidFerry: _avoidFerry,
        ),
      );
    }
    debugPrint(
      'PLAN: BUILD ok pts=${points.length} '
      'dist=${route.distance}m stops=${route.stopCumulative.length} '
      'alts=${alternatives.length}',
    );
    if (!mounted) return;
    setState(() {
      _route = route;
      _alternativeRoutes = alternatives;
      _selectedRoute = 0;
      _planPoints = points;
      _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      _destination = _stops.last.pos;
      _navigating = false;
      _progress = null;
      _routeStartIndex = 0; // brand-new route → draw the whole thing
      _updateDragHandles(route);
    });
    unawaited(_loadElevation(route));
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  /// Switch to alternative route [i] (Google's tap-to-choose preview).
  void _selectAlternative(int i) {
    if (i < 0 || i >= _alternativeRoutes.length || i == _selectedRoute) return;
    final route = _alternativeRoutes[i];
    debugPrint(
      'PLAN: alternative $i selected '
      'dist=${route.distance}m',
    );
    setState(() {
      _selectedRoute = i;
      _route = route;
      _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
      _updateDragHandles(route);
    });
    unawaited(_loadElevation(route));
    if (_planPoints.length >= 2) {
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(_planPoints),
          padding: const EdgeInsets.all(60),
        ),
      );
    }
  }

  List<String> _engineStopNames(OsrmRoute route) =>
      route.stopCumulative.length == _stops.length
      ? [for (final s in _stops) s.name]
      : const [];

  /// Switch the road type (ô tô / xe máy / xe đạp / đi bộ) and re-plan.
  void _setRouteProfile(RouteProfile p) {
    if (p == _routeProfile) return;
    setState(() => _routeProfile = p);
    if (_stops.isNotEmpty) {
      _buildPlanRoute(); // re-route with the new mode of transport
    }
  }

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
        _alternativeRoutes = [];
        _selectedRoute = 0;
        _planPoints = [];
        _showSteps = false;
        _dragHandles = [];
        _elevation = null;
        _pois = [];
        _poiType = null;
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
    _spokenFar = false;
    _spokenNear = false;
    _spokenFinal = false;
    _arrivedSpoken = false;
    _lastManeuverSig = null;
    _offRouteSince = null;
    _routeStartIndex = 0; // full route at the start of navigation
    _gpsWindow.clear();
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
      _routeStartIndex = 0;
      _roadInfo = null;
      _stops.clear();
      _showSteps = false;
      _alternativeRoutes = [];
      _selectedRoute = 0;
      _planPoints = [];
      _dragHandles = [];
      _elevation = null;
      _pois = [];
      _poiType = null;
      _selectedPoi = null;
    });
    _offRouteSince = null;
    _gpsWindow.clear();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('BLE: $e')));
      }
    }
  }

  // ---- map helpers -----------------------------------------------------

  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  /// Vietmap-style "overview" button: fit the camera to the whole route
  /// (leaving room for the top banner and the bottom ETA bar).
  void _overviewRoute() {
    final r = _route;
    if (r == null || r.geometry.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(r.geometry);
    _map.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(50, 170, 50, 240),
      ),
    );
  }

  // ---- voice: spoken turn-by-turn (Bluetooth speaker) ------------------

  /// Speak the upcoming maneuver AHEAD of the turn at speed-aware distances
  /// so the Bluetooth-speaker announcement always lands before the maneuver
  /// (never after it): first heads-up ~`max(150, speed×20)` m out, a closer
  /// heads-up ~`max(80, speed×8)` m, then a final "rẽ trái" at ~40 m. At
  /// speed, the callouts move earlier; the fixed fallbacks keep them sane
  /// when stationary.
  void _maybeSpeakManeuver(NavProgress nav) {
    if (!_voiceOn || !_voice.ready) return;
    if (nav.iconCode == iconArrive) {
      if (_arrivedSpoken) return;
      _arrivedSpoken = true;
      _voice.speak('Bạn đã đến nơi.');
      return;
    }
    final m = nav.meter;
    final speed = nav.speedMps.isFinite ? nav.speedMps : 0.0;
    // Head-up callouts are timed in SECONDS before the maneuver so they ALWAYS
    // sound ahead of the turn (never after — even with TTS + Bluetooth
    // latency): far ≈ 20 s out, near ≈ 12 s out, final ≈ 8 s out. On a long
    // straight stretch nothing repeats until the next maneuver gets close.
    final far = max(200.0, speed * 20.0); // first heads-up (20 s out)
    final near = max(120.0, speed * 12.0); // closer heads-up (12 s out)
    final finalM = max(80.0, speed * 8.0); // final "rẽ trái" (8 s out)
    // A maneuver is new when the turn instruction changes. The signature
    // includes the street you turn INTO (`nextText`) + the maneuver's
    // coordinates so two CONSECUTIVE turns that share the same icon + road
    // name (complex multi-turn areas) still count as different and each is
    // announced. (The old "distance jumped up by 50 m" test misfired on
    // GPS/SIM jitter, re-announcing the same turn.)
    final mv = nav.maneuver;
    final sig =
        '${nav.iconCode}|${nav.nextText}|'
        '${mv?.latitude.toStringAsFixed(5) ?? '0'},'
        '${mv?.longitude.toStringAsFixed(5) ?? '0'}';
    final isNew = sig != _lastManeuverSig;
    if (isNew) {
      _lastManeuverSig = sig;
      _spokenFar = false;
      _spokenNear = false;
      _spokenFinal = false;
    }
    if (isNew && m > far) {
      // Fresh turn → announce it immediately with its distance.
      _spokenFar = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenFar && m <= far && m > near) {
      _spokenFar = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenNear && m <= near && m > finalM) {
      _spokenNear = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spokenFinal && m <= finalM) {
      _spokenFinal = true;
      _voice.speak(_announce(nav, m, now: true));
    }
  }

  String _announce(NavProgress nav, int m, {bool now = false}) {
    final verb = maneuverVerb(nav.iconCode);
    // Announce the street you turn INTO (the upcoming step's road), not the
    // current one — "rẽ trái vào <incoming street>". Falls back to the
    // current road only when the next street is unknown (e.g. arrival).
    final target = nav.nextText.isNotEmpty ? nav.nextText : nav.text;
    final road = target.isNotEmpty ? ' vào $target' : '';
    return now ? '$verb$road' : 'Sau $m mét, $verb$road';
  }

  // ---- voice: commands (mic) -------------------------------------------

  Future<void> _toggleListening() async {
    if (_listening) {
      _listening = false;
      if (mounted) setState(() {});
      await _commands.stop();
      return;
    }
    if (!_commands.available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thiết bị này không hỗ trợ nhận diện giọng nói.'),
          ),
        );
      }
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cần quyền micro để điều khiển bằng giọng nói.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _listening = true);
    await _commands.listen(_onVoiceResult);
  }

  void _onVoiceResult(String text) {
    _listening = false;
    if (mounted) setState(() {});
    debugPrint('VOICE: recognized "$text"');
    final cmd = parseVoiceCommand(text);
    switch (cmd.type) {
      case VoiceCommandType.searchAndNavigate:
        _voiceSearchAndNavigate(cmd.query, cmd.navigate);
      case VoiceCommandType.start:
        _voice.speak('Bắt đầu chỉ đường.');
        _startNavigation();
      case VoiceCommandType.stop:
        _voice.speak('Đã dừng chỉ đường.');
        _exitNavigation();
      case VoiceCommandType.zoomIn:
        _zoomBy(1);
      case VoiceCommandType.zoomOut:
        _zoomBy(-1);
      case VoiceCommandType.voiceOn:
        setState(() => _voiceOn = true);
        _voice.speak('Đã bật hướng dẫn bằng giọng nói.');
      case VoiceCommandType.voiceOff:
        _voice.stop();
        setState(() => _voiceOn = false);
      case VoiceCommandType.help:
        _voice.speak(
          'Bạn có thể nói: chỉ đường tới chợ Bến Thành, bắt đầu, dừng lại, phóng to, thu nhỏ, bật tiếng, tắt tiếng.',
        );
      case VoiceCommandType.none:
        _voice.speak('Xin lỗi, tôi không hiểu lệnh.');
    }
  }

  Future<void> _voiceSearchAndNavigate(String query, bool navigate) async {
    if (query.isEmpty) {
      _voice.speak('Bạn muốn tìm địa điểm nào?');
      return;
    }
    _searchCtrl.text = query;
    final r = await osmAutocomplete(query);
    if (r.isEmpty) {
      _voice.speak('Không tìm thấy địa điểm $query.');
      return;
    }
    final s = r.first;
    _voice.speak('Đã tìm thấy ${s.display}.');
    await _selectSuggestion(s);
    if (navigate && mounted) {
      _voice.speak('Bắt đầu chỉ đường.');
      _startNavigation();
    }
  }

  /// Cycle the car marker icon (arrow → fun emojis).
  void _cycleCarIcon() {
    final i = kCarIcons.indexOf(_carIcon);
    setState(() => _carIcon = kCarIcons[(i + 1) % kCarIcons.length]);
  }

  /// "Điểm 2/3" for multi-stop trips ('' for a single destination).
  String _stopLabel(NavProgress? nav) => (nav?.totalStops ?? 0) > 1
      ? 'Điểm ${(nav!.stopIndex + 1)}/${nav.totalStops}'
      : '';

  // ---- Vietmap's own navigation SDK ------------------------------------

  /// Long-press the map to insert a via point and re-plan (interactive
  /// route editing on the OSM/offline map).
  void _addViaPoint(LatLng pos) {
    final stops = List<TripStop>.of(_stops);
    if (stops.isNotEmpty) {
      stops.insert(
        stops.length - 1,
        TripStop(name: 'Điểm giữa', lat: pos.latitude, lng: pos.longitude),
      );
    }
    setState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();
  }

  /// Min distance (meters) from [p] to a polyline — used to make the
  /// alternative route lines tappable.
  double _distToLine(LatLng p, List<LatLng> poly) {
    if (poly.isEmpty) return double.infinity;
    var best = distanceMeters(p, poly.first);
    for (var i = 1; i < poly.length; i++) {
      final d = distanceMeters(p, poly[i]);
      if (d < best) best = d;
    }
    return best;
  }

  // ---- draggable route handles -----------------------------------------

  /// One drag handle per route segment (origin→stop1, stop1→stop2, …).
  /// A simple A→B route gets exactly one handle; adding stops or a long
  /// trip yields one per segment.
  void _updateDragHandles(OsrmRoute? route) {
    _dragHandles = [];
    final g = route?.geometry ?? const <LatLng>[];
    if (route == null || g.length < 2 || _stops.isEmpty) return;
    final cum = route.stopCumulative;
    for (var j = 0; j < _stops.length; j++) {
      final cStart = j == 0 ? 0.0 : (j - 1 < cum.length ? cum[j - 1] : 0);
      final cEnd = j < cum.length ? cum[j] : route.distance;
      final dist = route.distance <= 0 ? 1.0 : route.distance;
      final frac = ((cStart + cEnd) / 2) / dist;
      final idx = (frac * (g.length - 1)).round().clamp(0, g.length - 1);
      _dragHandles.add(g[idx]);
    }
  }

  /// The user finished dragging handle [segIndex] → insert the point as a
  /// via stop in that segment and re-plan (the route now goes through it).
  void _commitDragHandle(int segIndex) {
    if (segIndex < 0 || segIndex >= _dragHandles.length) return;
    final via = _dragHandles[segIndex];
    final stops = List<TripStop>.of(_stops);
    final idx = segIndex.clamp(0, stops.length);
    stops.insert(
      idx,
      TripStop(name: 'Điểm giữa', lat: via.latitude, lng: via.longitude),
    );
    setState(() {
      _stops
        ..clear()
        ..addAll(stops);
    });
    _buildPlanRoute();
  }

  /// Best-effort elevation (ascent/descent) for the route card, cached per
  /// route. Never fatal — shows nothing when it can't be fetched.
  Future<void> _loadElevation(OsrmRoute route) async {
    final key = '${route.distance.round()}:${route.geometry.length}';
    final cached = _elevationCache[key];
    if (cached != null) {
      if (mounted) setState(() => _elevation = cached);
      return;
    }
    final e = await fetchRouteElevation(route.geometry);
    if (e != null) _elevationCache[key] = e;
    if (mounted) setState(() => _elevation = e);
  }

  /// Re-plan avoiding motorways (traffic/road-type criteria).
  void _toggleAvoidHighway() {
    setState(() => _avoidHighway = !_avoidHighway);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }

  /// Re-plan avoiding ferries.
  void _toggleAvoidFerry() {
    setState(() => _avoidFerry = !_avoidFerry);
    if (_stops.isNotEmpty) _buildPlanRoute();
  }

  /// Toggle the 3D perspective tilt on the navigation map (2D flat ↔ 3D).
  void _toggle3d() {
    setState(() => _tilt3d = !_tilt3d);
  }

  // ---- quick POI search (gas / food / hotel / …) -----------------------

  Widget _poiArea() {
    return _pois.isEmpty ? _poiTypeBar() : _poiResults();
  }

  Widget _poiTypeBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final t in PoiType.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: Colors.white,
                elevation: 4,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _searchPoi(t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_poiBusy && _poiType == t)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(t.icon, size: 16, color: poiColor(t)),
                        const SizedBox(width: 6),
                        Text(
                          t.label,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _poiResults() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
          child: Row(
            children: [
              Text(
                '${_poiType?.label ?? ''} gần đây',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (_selectedPoi != null)
                TextButton(
                  onPressed: () => _rerouteToPoi(_selectedPoi!),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFFFF6F00),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  child: const Text('Đi đến', style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: () => setState(() {
                  _pois = [];
                  _poiType = null;
                  _selectedPoi = null;
                }),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Đóng', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 76,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _pois.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _poiCard(_pois[i]),
          ),
        ),
      ],
    );
  }

  Widget _poiCard(PoiResult p) {
    final d = _current == null ? 0.0 : distanceMeters(_current!, p.pos);
    final col = poiColor(p.type);
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showPoiOnMap(p),
        child: Container(
          width: 180,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(p.type.icon, size: 16, color: col),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${formatDistance(d)} • ${p.type.label}',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Find the nearest POIs of [type] around the current position and
  /// highlight them on the map.
  Future<void> _searchPoi(PoiType type) async {
    final c = _current ?? _origin;
    if (c == null) return;
    setState(() {
      _poiBusy = true;
      _poiType = type;
      _selectedPoi = null;
    });
    try {
      final r = await searchPois(type, c);
      if (!mounted) return;
      setState(() => _pois = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _poiBusy = false);
    }
  }

  /// Show a tapped POI on the map: center the camera on it (pausing the
  /// follow) so the user can see where it is before deciding to go there.
  void _showPoiOnMap(PoiResult p) {
    setState(() => _selectedPoi = p);
  }

  /// Navigate to a picked POI, keeping the current navigation running.
  ///
  /// When a destination is already planned (the user is driving somewhere),
  /// the POI is ADDED as a stop / waypoint just before the destination —
  /// the final destination (and any other planned stops) is never dropped:
  /// origin → … → gas station → destination. With no planned destination the
  /// POI simply becomes the destination.
  Future<void> _rerouteToPoi(PoiResult p) async {
    final from = _current ?? _origin;
    if (from == null) return;
    try {
      final poiStop = TripStop(name: p.name, lat: p.lat, lng: p.lng);
      final alreadyPlanned = _stops.any(
        (s) => (s.lat - p.lat).abs() < 1e-5 && (s.lng - p.lng).abs() < 1e-5,
      );
      final List<TripStop> newStops;
      if (alreadyPlanned) {
        newStops = List.of(_stops); // same stop again → no change
      } else if (_stops.isEmpty) {
        newStops = [poiStop]; // no destination yet → POI becomes destination
      } else {
        newStops = [
          ..._stops.sublist(0, _stops.length - 1), // planned stops (kept)
          poiStop, // gas station waypoint (added)
          _stops.last, // final destination — never forgotten
        ];
      }
      final points = [from, for (final s in newStops) s.pos];
      final routes = await fetchAnyRoutes(
        points,
        profile: _routeProfile,
        avoidHighway: _avoidHighway,
        avoidFerry: _avoidFerry,
      );
      final route = routes.first;
      if (!mounted) return;
      setState(() {
        _stops
          ..clear()
          ..addAll(newStops);
        _destination = newStops.last.pos;
        _route = route;
        _engine = TurnByTurnEngine(route, stopNames: _engineStopNames(route));
        _alternativeRoutes = routes.length > 1 ? routes : [];
        _selectedRoute = 0;
        _planPoints = points;
        _pois = [];
        _poiType = null;
        _selectedPoi = null;
        _updateDragHandles(route);
      });
      unawaited(_loadElevation(route));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              alreadyPlanned
                  ? 'Đã có “${p.name}” trong hành trình.'
                  : _stops.length == 1
                  ? 'Đi đến “${p.name}”.'
                  : 'Đã thêm “${p.name}” vào điểm dừng — giữ điểm đến '
                        '${_stops.last.name}.',
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      if (_current != null) {
        final nav = _engine!.update(_current!);
        _progress = nav;
        _sendToClock(nav);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Không định tuyến được: $e')));
      }
    }
  }

  /// Switch the basemap layer (OSM → CARTO → Topo → Satellite → …).
  void _cycleTileLayer() {
    final i = _tileLayerNames.indexOf(_tileSource);
    final next = _tileLayerNames[(i + 1) % _tileLayerNames.length];
    setState(() {
      _tileSource = next;
      _tileProvider = OfflineTileProvider(source: next);
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Bản đồ: $_tileSource'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

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
    final plan = await Navigator.of(
      context,
    ).push<TripPlan>(MaterialPageRoute(builder: (_) => const TripsScreen()));
    if (plan != null && mounted) {
      setState(() {
        _stops
          ..clear()
          ..addAll(plan.stops);
        _destination = plan.stops.isEmpty ? null : plan.stops.last.pos;
      });
      _buildPlanRoute();
    }
  }

  Future<void> _openOffline() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const OfflineScreen()));
    // The user may have changed the data source — reload it.
    if (!mounted) return;
    final s = await loadSettings();
    dataSource = s.dataSource;
    setState(() {});
  }

  // ---- UI composition --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final route = _route;
    final current = _current;
    return Scaffold(
      body: Stack(
        children: [
          // Navigation mode renders the offline VECTOR map with the
          // Vietmap-navigation-style banner + ETA bar (ui/nav_top_bar.dart +
          // ui/navigation_card.dart). Browsing/search keeps the raster map.
          _navigating
              ? VectorNavMap(
                  routeGeometry: route?.geometry ?? const [],
                  routeSteps: route?.steps ?? const [],
                  routeStartIndex: _routeStartIndex,
                  current: current,
                  heading: _heading,
                  headingUp: _headingUp,
                  tilt3D: _tilt3d,
                  carIcon: _carIcon,
                  pois: _pois,
                  selectedPoi: _selectedPoi,
                  controller: _vmFollow,
                )
              : _buildMap(route, current),
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Pin the top area to the top — the banner and, under it,
                  // the road-info chip flow together so a tall banner (long
                  // destination / expanded step list) can never overlap the
                  // chip.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _navigating ? _navTopBar() : _topBar(),
                        if (_navigating)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 10, 0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                RoadInfoChip(
                                  info: _roadInfo,
                                  loading: _roadLoading,
                                  speedMps: _progress?.speedMps,
                                ),
                                const Spacer(),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    RoundActionButton(
                                      icon: _headingUp
                                          ? Icons.explore
                                          : Icons.navigation,
                                      color: _headingUp
                                          ? kAppBlue
                                          : const Color(0xFF5F6368),
                                      onTap: () => setState(
                                        () => _headingUp = !_headingUp,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: _tilt3d
                                          ? Icons.threed_rotation
                                          : Icons.map,
                                      color: _tilt3d
                                          ? kAppBlue
                                          : const Color(0xFF5F6368),
                                      onTap: _toggle3d,
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: Icons.emoji_emotions_outlined,
                                      color: const Color(0xFFF4B400),
                                      onTap: _cycleCarIcon,
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: _voiceOn
                                          ? Icons.volume_up
                                          : Icons.volume_off,
                                      color: _voiceOn
                                          ? const Color(0xFF34A853)
                                          : const Color(0xFF5F6368),
                                      onTap: () =>
                                          setState(() => _voiceOn = !_voiceOn),
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: _listening
                                          ? Icons.mic
                                          : Icons.mic_none,
                                      color: _listening
                                          ? const Color(0xFFEA4335)
                                          : const Color(0xFFF4B400),
                                      onTap: _toggleListening,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
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
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            children: const [
                              Icon(
                                Icons.cloud_off,
                                size: 16,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Đang ngoại tuyến — bản đồ & lộ trình đã tải vẫn hoạt động',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
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
                  // Raster-only controls (zoom/locate target the raster map
                  // controller) — hide during vector navigation mode.
                  if (!_navigating)
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
                            color: _simulating
                                ? Colors.orange
                                : const Color(0xFF34A853),
                            onTap: _toggleSimulation,
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon: Icons.download_for_offline_outlined,
                            color: kAppBlue,
                            onTap: _openOffline,
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon: Icons.layers_outlined,
                            color: const Color(0xFF7B1FA2),
                            onTap: _cycleTileLayer,
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
                  // Auto-center button — rendered in this overlay so it sits
                  // ABOVE the MapLibre platform view (a sibling inside the
                  // map's own Stack is occluded by it). Blue when the user
                  // has panned/zoomed away (follow paused); tapping recenters
                  // the camera on the car and resumes auto-follow. `bottom`
                  // is logical dp: the POI bar + ETA card are ~110dp tall, so
                  // 140dp clears them (a value like 340dp would sit mid-screen).
                  Positioned(
                    right: 14,
                    bottom: 140,
                    child: ListenableBuilder(
                      listenable: _vmFollow,
                      builder: (context, child) {
                        final following = _vmFollow.following;
                        return Material(
                          color: following
                              ? Colors.white
                              : const Color(0xFF1A73E8),
                          shape: const CircleBorder(),
                          elevation: 6,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _vmFollow.recenter,
                            child: Padding(
                              padding: const EdgeInsets.all(11),
                              child: Icon(
                                Icons.my_location,
                                color: following
                                    ? const Color(0xFF1A73E8)
                                    : Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: current ?? const LatLng(10.8231, 106.6297),
            initialZoom: 13,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            // Keep the route drag handle glued to its point while panning.
            onPositionChanged: (cam, _) => _camNotifier.value = cam,
            // Google-style interactive route editing on the preview map:
            // tap an alternative route line to select it, long-press to add
            // a via point and re-plan.
            onTap: (_, tapPos) {
              if (_navigating || _alternativeRoutes.length <= 1) return;
              for (var i = 0; i < _alternativeRoutes.length; i++) {
                if (i == _selectedRoute) continue;
                if (_distToLine(tapPos, _alternativeRoutes[i].geometry) <
                    0.05 /* ~50m */ ) {
                  _selectAlternative(i);
                  return;
                }
              }
            },
            onLongPress: (_, pos) {
              if (!_navigating) {
                _addViaPoint(pos);
              }
            },
          ),
          children: [
            TileLayer(
              // Basemap layer (changeable): OSM / CARTO / OpenTopoMap / ESRI
              // satellite. Requests are throttled to the OSM tile policy and
              // auto-fail over; each layer caches under its own folder so
              // styles never mix.
              urlTemplate: _tileLayers[_tileSource],
              userAgentPackageName: 'com.navbridge.app',
              tileProvider: _tileProvider,
            ),
            if (route != null)
              PolylineLayer(
                polylines: [
                  // Alternative routes drawn dimmed (Google's tap-to-compare).
                  for (var i = 0; i < _alternativeRoutes.length; i++)
                    if (i != _selectedRoute)
                      Polyline(
                        points: _alternativeRoutes[i].geometry,
                        color: const Color(0xFF9BB2E8),
                        strokeWidth: 5,
                      ),
                  // white casing under the blue route (Google look)
                  Polyline(
                    points: route.geometry,
                    color: Colors.white,
                    strokeWidth: 9,
                  ),
                  Polyline(
                    points: route.geometry,
                    color: kAppBlue,
                    strokeWidth: 6,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (_origin != null)
                  Marker(
                    point: _origin!,
                    width: 30,
                    height: 30,
                    child: const OriginMarker(),
                  ),
                // numbered markers for intermediate stops (the last stop is
                // the red destination pin below)
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
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
                // POI quick-search highlights.
                for (final p in _pois)
                  Marker(
                    point: p.pos,
                    width: 26,
                    height: 26,
                    child: Container(
                      decoration: BoxDecoration(
                        color: poiColor(p.type),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                      child: Icon(p.type.icon, size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ],
        ),
        // Google-style draggable route handles (preview mode only): one per
        // segment — a simple route has exactly one.
        if (!_navigating && route != null && _dragHandles.isNotEmpty)
          for (var i = 0; i < _dragHandles.length; i++)
            _RouteDragHandle(
              key: ValueKey('drag$i'),
              via: _dragHandles[i],
              cameraListenable: _camNotifier,
              onDrag: (delta) {
                final cam = _map.camera;
                final cur = cam.latLngToScreenPoint(_dragHandles[i]);
                final next = cam.pointToLatLng(
                  Point(cur.x + delta.dx, cur.y + delta.dy),
                );
                setState(() => _dragHandles[i] = next);
              },
              onDragEnd: () => _commitDragHandle(i),
            ),
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
          RoundActionButton(
            icon: _listening ? Icons.mic : Icons.mic_none,
            color: _listening ? const Color(0xFFEA4335) : kAppBlue,
            onTap: _toggleListening,
            size: 44,
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
      stopLabel: _stopLabel(nav),
      steps: _route?.steps ?? const [],
      expanded: _showSteps,
      onToggle: () => setState(() => _showSteps = !_showSteps),
      onExit: _exitNavigation,
    );
  }

  Widget _bottomArea() {
    final route = _route;
    final nav = _progress;
    final stopLabel = _stopLabel(nav);
    final Widget? card;
    if (_navigating) {
      // Google-style arrival card when the destination is reached, otherwise
      // the Vietmap-style ETA bar (ui/navigation_card.dart).
      if (nav != null && nav.iconCode == iconArrive) {
        card = ArrivalCard(
          progress: nav,
          onStop: _exitNavigation,
          stopLabel: stopLabel,
        );
      } else {
        card = NavigationCard(
          progress: _progress,
          onStop: _exitNavigation,
          onOverview: _overviewRoute,
          stopLabel: stopLabel,
        );
      }
    } else if (route != null) {
      card = RoutePreviewCard(
        etaText: '${(route.duration / 60).round()} ph',
        distanceText: formatDistance(route.distance),
        destination: _destinationName,
        stopCount: _stops.length,
        profile: _routeProfile,
        onProfile: _setRouteProfile,
        onStart: _startNavigation,
        onClear: _exitNavigation,
        tollCost: route.tollCost,
        alternativeLabels: [
          for (final r in _alternativeRoutes)
            '${(r.duration / 60).round()} ph • ${formatDistance(r.distance)}',
        ],
        selectedAlternative: _selectedRoute,
        onAlternative: _selectAlternative,
        avoidHighway: _avoidHighway,
        onToggleAvoidHighway: _toggleAvoidHighway,
        avoidFerry: _avoidFerry,
        onToggleAvoidFerry: _toggleAvoidFerry,
        elevation: _elevation,
      );
    } else {
      card = null;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_navigating) _poiArea(),
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

/// Google-style draggable route handle: a grab dot on the route that the
/// user drags to insert a via point and re-plan. Drawn as a Flutter widget
/// on top of the map so its pan gesture doesn't fight the map's own pan.
class _RouteDragHandle extends StatelessWidget {
  const _RouteDragHandle({
    super.key,
    required this.via,
    required this.cameraListenable,
    required this.onDrag,
    required this.onDragEnd,
  });

  final LatLng via;
  final ValueListenable<MapCamera?> cameraListenable;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MapCamera?>(
      valueListenable: cameraListenable,
      builder: (context, cam, _) {
        if (cam == null) return const SizedBox.shrink();
        final p = cam.latLngToScreenPoint(via);
        return Positioned(
          left: p.x - 18,
          top: p.y - 18,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => onDrag(d.delta),
            onPanEnd: (_) => onDragEnd(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: kAppBlue, width: 3),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 4),
                ],
              ),
              child: const Icon(Icons.drag_handle, size: 16, color: kAppBlue),
            ),
          ),
        );
      },
    );
  }
}
