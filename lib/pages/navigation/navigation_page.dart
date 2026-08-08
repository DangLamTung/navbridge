/// OpenStreetMap turn-by-turn navigation mirrored to the E-ink clock over BLE.
///
/// This page owns the app state (GPS, search, routing, BLE) and composes the
/// map with the small UI widgets in `ui/`. Each widget file is self-contained:
///
///   - [SearchPill]            top search bar
///   - [SuggestionList]        Nominatim results
///   - [MapControls]           zoom +/− and locate buttons
///   - [DisplaysButton]        combined BLE displays connection state
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
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:navbridge/services/ble_clock.dart';
import 'package:navbridge/services/ble_map_clock.dart';
import 'package:navbridge/ui/device_picker.dart';
import 'package:navbridge/services/elevation.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/core/map_protocol.dart';
import 'package:navbridge/pages/offline_screen.dart';
import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/services/offline_router.dart';
import 'package:navbridge/services/offline_tiles.dart';
import 'package:navbridge/services/poi_search.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/pages/trips_screen.dart';
import 'package:navbridge/ui/arrival_card.dart';
import 'package:navbridge/ui/vector_nav_map.dart';
import 'package:navbridge/services/vietmap_api.dart';
import 'package:navbridge/services/vietmap_config.dart';
import 'package:navbridge/services/voice_commands.dart';
import 'package:navbridge/services/voice_guide.dart';
import 'package:navbridge/services/weather.dart';
import 'package:navbridge/ui/displays_button.dart';
import 'package:navbridge/ui/elevation_chart.dart';
import 'package:navbridge/ui/map_controls.dart';
import 'package:navbridge/ui/nav_status_bar.dart';
import 'package:navbridge/ui/nav_top_bar.dart';
import 'package:navbridge/ui/navigation_card.dart';
import 'package:navbridge/ui/poi_info_card.dart';
import 'package:navbridge/ui/road_info_chip.dart';
import 'package:navbridge/ui/route_preview_card.dart';
import 'package:navbridge/ui/search_pill.dart';
import 'package:navbridge/ui/stops_panel.dart';
import 'package:navbridge/ui/suggestions_list.dart';
import 'package:navbridge/ui/widgets.dart';

part 'nav_bars.dart';
part 'nav_gps.dart';
part 'nav_map.dart';
part 'nav_navigation.dart';
part 'nav_poi.dart';
part 'nav_route_edit.dart';
part 'nav_screens.dart';
part 'nav_search.dart';
part 'nav_voice.dart';
part 'nav_weather.dart';

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});

  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage>
    with WidgetsBindingObserver {
  final MapController _map = MapController();
  final BleClock _clock = BleClock();

  /// BLE client for the ESP32 2.8" navigation display (NAV-OSM board).
  final BleMapClock _mapClock = BleMapClock();

  /// setState wrapper exposed to the navigation `part` extensions (nav_*.dart),
  /// which are not State subclasses and so can't call the protected
  /// [State.setState] directly. This keeps a single rebuild path for the page.
  void setNavState(VoidCallback fn) => setState(fn);

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

  /// True once the browse map has been panned to the first real GPS fix, so
  /// the "you are here" dot is on screen (the map starts at the default HCMC
  /// centre, which can be far from the user's real position).
  bool _centeredOnGps = false;

  /// Smoothed route-ahead bearing (deg, 0=N) from `engine.routeBearing()` —
  /// the direction of the road ahead, low-pass filtered so the arrow and the
  /// heading-up camera never flicker. Passed to the vector map as `bearing`.
  double _routeBearing = 0;

  bool _headingUp = true; // rotate map so travel direction points up
  String _carIcon = 'arrow';
  RouteProfile _routeProfile = RouteProfile.car; // road type for routing
  NavProgress? _progress;
  StreamSubscription<Position>? _gpsSub;
  bool _navigating = false;
  String _clockStatus = 'off';
  String _mapStatus = 'off';

  /// Last minute sent to the ESP32 display's HUD clock — the current time is
  /// only pushed when the minute ticks over.
  int _lastMapClockMinute = -1;

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
  bool _elevationExpanded =
      false; // expand the elevation chart on the nav screen

  /// Current air temperature (°C) for the bottom status bar (Open-Meteo).
  WeatherInfo? _weather;
  Timer? _weatherTimer; // refreshes the weather while navigating
  double? _scrubProgress; // 0..1 while the user drags the progress line

  // --- nav map: 3D perspective tilt (Google-style) ----------------------
  bool _tilt3d = true; // tilted perspective camera (turn off = flat 2D)
  bool _terrain3d = false; // true 3D terrain relief (needs offline DEM)
  bool _nightMode = false; // night/dark map
  bool _satellite = false; // satellite imagery basemap (real terrain)
  bool _showStatusBar = true; // Google-style bottom time bar
  NavBarMode _barMode = NavBarMode.time; // bottom slide: time or elevation

  // --- quick POI search (gas / food / hotel / … during navigation) ------
  List<PoiResult> _pois = [];
  PoiType? _poiType;
  PoiResult? _selectedPoi; // tapped POI — shown on the map until "Đi đến"
  bool _poiBusy = false;

  // --- offline POI browse (bundled vietnam_pois.json) --------------------
  List<OfflinePoiCategory>? _offlinePoiCats; // loaded lazily once
  bool _offlinePoiBusy = false;
  String? _offlinePoiCatLoading; // category key currently loading

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
    // Vietmap layers need the tile key (--dart-define=VIETMAP_TILE_KEY).
    // Without it their URLs carry `?apikey=` and every tile 403s, so the
    // menu only lists them when real keys were compiled in (see below).
    'vietmap': VietmapConfig.mapTiles,
    'vietmapsat': VietmapConfig.satelliteTiles,
  };

  /// Basemap layer names in menu order. Vietmap layers are only offered when
  /// real keys were provided at build time.
  List<String> get _tileLayerNames => [
    'osm',
    'carto',
    'topo',
    'esri',
    if (VietmapConfig.hasKeys) ...['vietmap', 'vietmapsat'],
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
    WidgetsBinding.instance.addObserver(this);
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
    _mapClock.linkStream.listen((l) {
      if (!mounted) return;
      setState(() {
        _mapStatus = switch (l) {
          ClockLink.connected => 'connected',
          ClockLink.connecting => 'connecting',
          ClockLink.off => 'off',
        };
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await _requestPermission()) _startGps();
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
      if (_offline) unawaited(_ensureOfflinePoiCats());
    });
    isOnline().then((on) {
      if (!mounted) return;
      setState(() => _offline = !on || forceOffline);
      if (_offline) unawaited(_ensureOfflinePoiCats());
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

  /// When the app comes back to the foreground (e.g. after the user enabled
  /// the phone's GPS toggle or granted location permission in system
  /// settings), re-check and restart the GPS stream — otherwise a device with
  /// location services turned off would silently never get a fix.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_simulating) return;
    Future(() async {
      if (await _requestPermission() && !_simulating) _startGps();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    _mapClock.dispose();
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
  ///   - `NAVTEST_MOUNTAIN=true` → Đà Lạt (Lang Biang → Đà Lạt city) with 3D
  ///                           terrain ON, to verify hillshading/elevation in
  ///                           a mountainous region.
  ///   - `NAVTEST_OFFLINE=true` → HCMC, forceOffline=ON — routes + navigates
  ///                           using ONLY on-device data (GraphHopper graph +
  ///                           bundled saigon pmtiles). Needs the HCMC graph
  ///                           downloaded.
  /// Normal builds (no defines) are completely unaffected.

  // ---- GPS -------------------------------------------------------------

  /// Online GPS road-snapping: send the rolling trace to OSRM /match
  /// (throttled to 5 s) to refine the on-route position when online. The
  /// matched point is projected onto the route polyline and only accepted
  /// when it's close — between matches (and fully offline) the always-on
  /// `engine.snapToRoute` projection keeps the car on the road, so the match
  /// never causes the puck to bounce off/on the route (the old flicker).

  /// Restart the GPS stream shortly after it ends/errors — some devices
  /// drop the stream, which would silently freeze both the UI updates and
  /// the off-route re-routing.

  /// Shared by real GPS and the simulated drive: snap, update the card,
  /// push to the clock and keep the camera on the car.

  /// Look up the current road (type + speed limit). Prefers the on-device
  /// GraphHopper graph (instant + offline); falls back to Overpass.

  /// Road info straight from the on-device graph (nearest edge), with the
  /// same Vietnamese statutory defaults as the Overpass path.

  /// Feed the active trip logger (real GPS or simulated fixes).

  /// Start recording a trip (no-op if one is already active).

  /// Stop recording and save the trip to disk (Google Takeout Records.json).

  /// Re-navigation: fetch a fresh route from [from] to the destination.
  /// Keeps the current navigation running and snaps straight into the new
  /// route so the UI + clock update immediately.

  /// Start/stop the simulated drive along the current route.

  /// Inject realistic GPS error (±~12 m) into a SIM fix so road-snapping is
  /// exercised. The error is CROSS-TRACK (perpendicular to the road) — that's
  /// the component the snapping must correct; along-track error just slides
  /// the car forward/back on the road and adds no value. Only used by the
  /// NAVTEST harness (no effect on normal builds).

  // ---- search (Nominatim → OSRM route) ---------------------------------

  /// When forced-offline is active, ask the user whether to go online for an
  /// action that needs the network (search / routing). Accepting lifts the
  /// offline lock for THIS session only — the persisted setting is unchanged,
  /// so a restart goes back to forced offline. Returns true when the action
  /// may proceed online.

  /// Add [name]@[lat]/[lng] as the destination and build the route.

  /// Route through all planned stops (origin → stop1 → … → last stop).

  /// Switch to alternative route [i] (Google's tap-to-choose preview).

  /// Best-effort start position: live fix, last known, or the app default.
  /// Never throws; falls back to the default city (HCMC) when GPS is
  /// unavailable so route planning + simulation still work.

  // ---- BLE clock -------------------------------------------------------

  // ---- map helpers -----------------------------------------------------

  // ---- voice: spoken turn-by-turn (Bluetooth speaker) ------------------

  /// Speak the upcoming maneuver AHEAD of the turn at speed-aware distances
  /// so the Bluetooth-speaker announcement always lands before the maneuver
  /// (never after it): first heads-up ~`max(150, speed×20)` m out, a closer
  /// heads-up ~`max(80, speed×8)` m, then a final "rẽ trái" at ~40 m. At
  /// speed, the callouts move earlier; the fixed fallbacks keep them sane
  /// when stationary.

  // ---- voice: commands (mic) -------------------------------------------

  /// Cycle the car marker icon (arrow → fun emojis).

  /// "Điểm 2/3" for multi-stop trips ('' for a single destination).

  /// Min distance (meters) from [p] to a polyline — used to make the
  /// alternative route lines tappable.

  // ---- draggable route handles -----------------------------------------

  /// One drag handle per route segment (origin→stop1, stop1→stop2, …).
  /// A simple A→B route gets exactly one handle; adding stops or a long
  /// trip yields one per segment.

  /// The user finished dragging handle [segIndex] → insert the point as a
  /// via stop in that segment and re-plan (the route now goes through it).

  /// Best-effort elevation (ascent/descent) for the route card, cached per
  /// route. Never fatal — shows nothing when it can't be fetched.

  /// Re-plan avoiding motorways (traffic/road-type criteria).

  /// Re-plan avoiding ferries.

  /// Toggle night (dark) map mode.

  /// Toggle the Google-style bottom status bar (clock / distance / ETA).

  /// A styled layer-menu row (icon + label + active checkmark).
  PopupMenuItem<String> _layerItem(
    String value,
    IconData icon,
    String label,
    bool active,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 46,
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: active ? kAppBlue : const Color(0xFF5F6368),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF202124),
              ),
            ),
          ),
          if (active) const Icon(Icons.check, size: 18, color: kAppBlue),
        ],
      ),
    );
  }

  // ---- quick POI search (gas / food / hotel / …) -----------------------

  /// Lazily-loaded category chips for the BUNDLED offline POI index (ATM,
  /// xăng, nhà hàng, …) — browse "nearest X" with no network.

  /// Find the nearest POIs of [type] around the current position and
  /// highlight them on the map.

  /// Load the bundled offline POI index (once) so the category chips show.

  /// Browse one bundled offline category: show its POIs sorted by distance
  /// from the current position as search suggestions (tap → info card).

  /// Show a tapped POI on the map: center the camera on it (pausing the
  /// follow) so the user can see where it is before deciding to go there.

  /// Navigate to a picked POI, keeping the current navigation running.
  ///
  /// When a destination is already planned (the user is driving somewhere),
  /// the POI is ADDED as a stop / waypoint just before the destination —
  /// the final destination (and any other planned stops) is never dropped:
  /// origin → … → gas station → destination. With no planned destination the
  /// POI simply becomes the destination.

  /// Switch the basemap layer (OSM → CARTO → Topo → Satellite → …).

  // ---- trips history ---------------------------------------------------

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
                  bearing: _routeBearing,
                  heading: _heading,
                  headingUp: _headingUp,
                  tilt3D: _tilt3d,
                  terrain3D: _terrain3d,
                  nightMode: _nightMode,
                  satellite: _satellite,
                  // Vietmap light basemap in nav mode when the Vietmap data
                  // source is active, online, and real keys are compiled in.
                  vietmapBase:
                      dataSource == 'vietmap' &&
                      !_offline &&
                      VietmapConfig.hasKeys,
                  carIcon: _carIcon,
                  pois: _pois,
                  selectedPoi: _selectedPoi,
                  stops: _stops,
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
                                    // Map layers: 3D / terrain / satellite
                                    // grouped into ONE picker button.
                                    PopupMenuButton<String>(
                                      tooltip: 'Lớp bản đồ',
                                      position: PopupMenuPosition.under,
                                      offset: const Offset(-120, 8),
                                      color: Colors.white,
                                      elevation: 8,
                                      shadowColor: Colors.black38,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      onSelected: (v) {
                                        if (v == '3d') {
                                          setState(() => _tilt3d = !_tilt3d);
                                        } else if (v == 'terrain') {
                                          setState(
                                            () => _terrain3d = !_terrain3d,
                                          );
                                        } else if (v == 'satellite') {
                                          setState(
                                            () => _satellite = !_satellite,
                                          );
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        _layerItem(
                                          '3d',
                                          Icons.threed_rotation,
                                          '3D (nghiêng)',
                                          _tilt3d,
                                        ),
                                        _layerItem(
                                          'terrain',
                                          Icons.terrain,
                                          'Địa hình',
                                          _terrain3d,
                                        ),
                                        _layerItem(
                                          'satellite',
                                          Icons.satellite_alt,
                                          'Vệ tinh',
                                          _satellite,
                                        ),
                                      ],
                                      child: Material(
                                        color: Colors.white,
                                        elevation: 4,
                                        shadowColor: Colors.black26,
                                        shape: const CircleBorder(),
                                        child: SizedBox(
                                          width: 46,
                                          height: 46,
                                          child: Icon(
                                            Icons.layers,
                                            color:
                                                (_tilt3d ||
                                                    _terrain3d ||
                                                    _satellite)
                                                ? kAppBlue
                                                : const Color(0xFF5F6368),
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: _nightMode
                                          ? Icons.dark_mode
                                          : Icons.light_mode,
                                      color: _nightMode
                                          ? kAppBlue
                                          : const Color(0xFF5F6368),
                                      onTap: _toggleNight,
                                    ),
                                    const SizedBox(height: 8),
                                    RoundActionButton(
                                      icon: _showStatusBar
                                          ? Icons.bar_chart
                                          : Icons.bar_chart_outlined,
                                      color: _showStatusBar
                                          ? kAppBlue
                                          : const Color(0xFF5F6368),
                                      onTap: _toggleStatusBar,
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
                  // Offline POI category chips (ATM / xăng / nhà hàng / …)
                  // — shown while browsing, hidden while a route is being
                  // planned (suggestions take the spot below).
                  if (_offline && !_navigating && _suggestions.isEmpty)
                    Positioned(
                      top: _offline ? 104 : 70,
                      left: 12,
                      right: 66,
                      child: _offlinePoiBar(),
                    ),
                  if (!_navigating)
                    Positioned(
                      left: 12,
                      right: 66,
                      top: _offline ? (_suggestions.isEmpty ? 152 : 104) : 70,
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
                            icon: Icons.settings,
                            color: kAppBlue,
                            onTap: _openOffline,
                          ),
                          const SizedBox(height: 8),
                          PopupMenuButton<String>(
                            tooltip: 'Lớp bản đồ',
                            position: PopupMenuPosition.under,
                            offset: const Offset(-150, 8),
                            color: Colors.white,
                            elevation: 8,
                            shadowColor: Colors.black38,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            onSelected: _selectTileLayer,
                            itemBuilder: (context) => [
                              for (final name in _tileLayerNames)
                                _layerItem(
                                  name,
                                  _tileLayerIcon(name),
                                  _tileLayerLabel(name),
                                  name == _tileSource,
                                ),
                            ],
                            child: Material(
                              color: Colors.white,
                              elevation: 4,
                              shadowColor: Colors.black26,
                              shape: const CircleBorder(),
                              child: SizedBox(
                                width: 46,
                                height: 46,
                                child: Icon(
                                  Icons.layers_outlined,
                                  color: const Color(0xFF7B1FA2),
                                  size: 22,
                                ),
                              ),
                            ),
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

  /// Compact header shown while navigating (replaces the search bar).

  /// Minutes remaining to the destination (from remaining duration).

  /// Fixed arrival moment for the live ETA countdown on the navigation card
  /// (now + remaining duration). The card counts down to it every second.
  DateTime _arrivalTime() {
    final route = _route;
    final nav = _progress;
    if (route == null || route.duration <= 0) return DateTime.now();
    final remain = route.duration * (1 - (nav?.progress ?? 0));
    return DateTime.now().add(Duration(seconds: remain.round()));
  }

  /// While the user drags the progress line: remember the scrubbed fraction
  /// so the elevation marker + preview distance follow the finger.

  /// Compact elevation/terrain chart for the nav status bar (tap to
  /// expand/collapse). The progress marker follows the live progress, or the
  /// scrubbed preview while the user drags the progress line.
  Widget? _elevationChart(NavProgress? nav) {
    final e = _elevation;
    if (e == null || e.profile.isEmpty) return null;
    final progress = _scrubProgress ?? nav?.progress ?? 0;
    return GestureDetector(
      onTap: () => setState(() => _elevationExpanded = !_elevationExpanded),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.terrain, size: 16, color: kAppBlue),
              const SizedBox(width: 6),
              const Text(
                'Độ cao',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Icon(
                _elevationExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: const Color(0xFF5F6368),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ElevationChart(
            profile: e.profile,
            minElev: e.minElev,
            maxElev: e.maxElev,
            up: e.up,
            down: e.down,
            progress: progress,
            compact: !_elevationExpanded,
          ),
        ],
      ),
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
