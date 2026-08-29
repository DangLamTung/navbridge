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
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' show max, sin, cos, atan2;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:navbridge/services/ble_clock.dart';
import 'package:navbridge/services/ble_map_clock.dart';
import 'package:navbridge/services/ble_auto_connect.dart';
import 'package:navbridge/ui/device_picker.dart';
import 'package:navbridge/services/elevation.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/core/map_protocol.dart';
import 'package:navbridge/core/nmea_parser.dart';
import 'package:navbridge/pages/settings_screen.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/services/offline_router.dart';
import 'package:navbridge/services/offline_tiles.dart';
import 'package:navbridge/services/poi_search.dart';
import 'package:navbridge/services/google_places.dart';
import 'package:navbridge/core/gps_noise_simulator.dart';
import 'package:navbridge/core/heading_filter.dart';
import 'package:navbridge/core/location_kalman.dart';
import 'package:navbridge/core/outlier_gate.dart';
import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/quick_places.dart';
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/overlay_visibility.dart';
import 'package:navbridge/services/radar.dart';
import 'package:navbridge/services/route_export.dart';
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/ui/arrival_card.dart';
import 'package:navbridge/ui/cctv_icon.dart';
import 'package:navbridge/ui/vector_nav_map.dart';
import 'package:navbridge/services/vietmap_api.dart';
import 'package:navbridge/services/vietmap_config.dart';
import 'package:navbridge/pages/vietmap_nav_screen.dart';
import 'package:navbridge/services/ai_assistant.dart';
import 'package:navbridge/ui/ai_chat_panel.dart';
import 'package:navbridge/services/voice_commands.dart';
import 'package:navbridge/services/voice_guide.dart';
import 'package:navbridge/services/weather.dart';
import 'package:navbridge/services/nav_foreground.dart';
import 'package:navbridge/services/pip_service.dart';
import 'package:navbridge/ui/displays_button.dart';
import 'package:navbridge/ui/directions_bar.dart';
import 'package:navbridge/ui/elevation_chart.dart';
import 'package:navbridge/ui/map_controls.dart';
import 'package:navbridge/ui/nav_status_bar.dart';
import 'package:navbridge/ui/nav_top_bar.dart';
import 'package:navbridge/ui/navigation_card.dart';
import 'package:navbridge/ui/poi_info_card.dart';
import 'package:navbridge/ui/weather_time_bar.dart';
import 'package:navbridge/ui/road_info_chip.dart';
import 'package:navbridge/ui/route_preview_card.dart';
import 'package:navbridge/ui/search_pill.dart';
import 'package:navbridge/ui/stops_panel.dart';
import 'package:navbridge/ui/suggestions_list.dart';
import 'package:navbridge/ui/widgets.dart';

part 'modules/nav_bars.dart';
part 'modules/nav_build.dart';
part 'modules/nav_gates.dart';
part 'modules/nav_gps.dart';
part 'modules/nav_map.dart';
part 'modules/nav_navigation.dart';
part 'modules/nav_plan.dart';
part 'modules/nav_poi.dart';
part 'modules/nav_radar.dart';
part 'modules/nav_route_edit.dart';
part 'modules/nav_screens.dart';
part 'modules/nav_search.dart';
part 'modules/nav_signs.dart';
part 'modules/nav_simple.dart';
part 'modules/nav_voice.dart';
part 'modules/nav_weather.dart';
part 'modules/nav_widgets.dart';

/// Which directions-mode field a suggestion or map-tap fills.
enum _NavField { start, end }

/// App/isolate start — used to measure startup latency (first frame, graph
/// load timing) via the STARTUP / ROUTER debug logs.
final DateTime _appStart = DateTime.now();

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

  /// Automatic Bluetooth connection service for external displays.
  late final BleAutoConnectService _autoConnect;

  /// setState wrapper exposed to the navigation `part` extensions (nav_*.dart),
  /// which are not State subclasses and so can't call the protected
  /// [State.setState] directly. This keeps a single rebuild path for the page.
  void setNavState(VoidCallback fn) => setState(fn);

  // --- search -----------------------------------------------------------
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  /// True = Google-Maps-style DIRECTIONS mode (start + end fields, add
  /// stops, tap-map to pick points). False = plain search/browse mode where
  /// tapping a result drops a pin + shows a place card with a "Chỉ đường"
  /// button (no route is built until the user asks for directions).
  bool _directionsMode = false;

  /// Start-point controller for directions mode ("" = use current location).
  final _startCtrl = TextEditingController();
  final _startFocus = FocusNode();

  /// User-chosen start point (null = current location).
  LatLng? _originOverride;
  String _originName = '';

  /// Which directions field a suggestion / map-tap fills.
  _NavField _navField = _NavField.end;

  /// Place dropped in search (browse) mode — shown as a pin + place card
  /// with a "Chỉ đường" button (Google-Maps style). Null = no picked place.
  OsmSuggestion? _pickedPlace;

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

  /// Identity-keyed cache of DECIMATED route geometry for the browse map —
  /// a long-distance route's full polyline is reduced once (not on every
  /// 1 Hz rebuild), keeping the map fast right after routing.
  final Map<Object, List<LatLng>> _routeDisplayCache = {};

  /// 1 Hz gate for [_syncOverlayVisibility] — it's also hooked to map camera
  /// events (pan/zoom), which fire far faster than GPS. Without this gate the
  /// camera/speed lookups would hammer the main thread and ANR the app.
  DateTime? _lastOverlaySync;

  /// Index into the route polyline where the DRAWN route starts — the driven
  /// part is "consumed" (not drawn), Google-Maps style. Updated on every nav
  /// fix from `engine.snappedSegmentIndex`.
  int _routeStartIndex = 0;
  LatLng? _current;

  /// Strict GPS-heading filter ([StrictHeading]): holds the heading while the
  /// car is stationary and only applies a big change after two agreeing fixes,
  /// so the car arrow never spins in place. Exposes the filtered value via
  /// [_heading] (read by the map + trip logger).
  final StrictHeading _headingFilter = StrictHeading();
  double? get _heading => _headingFilter.heading;

  /// GPS outlier gate ([OutlierGate]): rejects inaccurate fixes and position
  /// jumps inconsistent with the recent smoothed speed before they reach the
  /// map / filter / speed chip (a single 130 km/h burst must never move the
  /// arrow or flash the speed).
  final OutlierGate _outlierGate = OutlierGate();

  /// ESP32 GPS bridge (ESP-first, phone fallback): the board's on-UART0
  /// receiver broadcasts a compact AA55 GPS frame (type 0x0A) over BLE; we
  /// parse it and use it FIRST (real antenna), falling back to the phone's GPS
  /// only when the ESP has no fresh fix. State lives here; parsing/feeding
  /// lives in nav_gps.dart.
  final NmeaParser _nmea = NmeaParser(); // legacy raw-NMEA path (kept)
  bool _espValid = false; // latest ESP frame has a fix (either protocol)
  DateTime? _espFixAt; // when the last ESP frame/line arrived
  DateTime? _espLastFeed; // throttle so pairs don't double-feed
  // The compact binary frame carries no speed/heading — derive from movement.
  LatLng? _espPrevPos;
  DateTime? _espPrevAt;
  double? _espSpeedMps;
  double? _espHeading;

  /// True once the browse map has been panned to the first real GPS fix, so
  /// the "you are here" dot is on screen (the map starts at the default HCMC
  /// centre, which can be far from the user's real position).
  bool _centeredOnGps = false;

  /// Smoothed route-ahead bearing (deg, 0=N) from `engine.routeBearing()` —
  /// the direction of the road ahead, low-pass filtered so the arrow and the
  /// heading-up camera never flicker. Passed to the vector map as `bearing`.
  double _routeBearing = 0;

  bool _headingUp = !const bool.fromEnvironment(
    'FORCE_NORTH',
  ); // rotate map so travel direction points up
  String _carIcon = 'arrow';
  RouteProfile _routeProfile = RouteProfile.car; // road type for routing
  NavProgress? _progress;
  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<ClockLink>? _clockSub;
  StreamSubscription<ClockLink>? _mapClockSub;
  StreamSubscription<String>? _mapGpsSub;
  StreamSubscription<Uint8List>? _mapGpsFrameSub;
  bool _navigating = false;

  /// True while the OS Picture-in-Picture window is on screen (nav only). When
  /// set, the page renders a compact PiP layout so the big banner/controls
  /// don't overflow the tiny floating window.
  bool _pipActive = false;
  String _clockStatus = 'off';
  String _mapStatus = 'off';

  /// Last minute sent to the ESP32 display's HUD clock — the current time is
  /// only pushed when the minute ticks over.
  int _lastMapClockMinute = -1;

  /// Last time the ESP display's path-ahead was re-sent. The board only shows
  /// ~1.5 km of map (zoom 15), so we push the near path-ahead window and
  /// refresh it on a timer while navigating — not on every GPS fix.
  DateTime? _lastMapRouteSend;

  // --- Google-style extras: step list, alternative routes ----------------
  bool _showSteps = false; // expanded turn-banner step list
  List<OsrmRoute> _alternativeRoutes = []; // Vietmap alternative routes
  int _selectedRoute = 0; // index into [_alternativeRoutes]
  List<LatLng> _planPoints = []; // route points for re-fitting the camera

  /// Serial for route builds — each [_buildPlanRoute] bumps it; a build whose
  /// number is stale (a newer build already started) drops its result, so a
  /// fast double-trigger (e.g. profile change + re-plan) never makes the
  /// route build/flicker twice.
  int _planSeq = 0;

  // --- route criteria: traffic / elevation / avoid highway / ferry -------
  bool _avoidHighway = false; // re-plan without motorways (OSRM)
  bool _avoidFerry = false; // re-plan without ferries (OSRM)
  RoutePreference _routePreference = RoutePreference.fastest; // route style
  bool _navStarting = false; // re-entry latch so nav can't start twice
  bool _topBarCollapsed = false; // directions bar collapsed to a compact pill
  bool _stopsCollapsed = false; // stops panel list collapsed to its header
  bool _routeOptionsCollapsed = true; // route card options section collapsed
  bool _routeCardCollapsed = true; // whole route card collapsed to a pill
  ElevationInfo? _elevation; // ascent/descent of the current route
  final Map<String, ElevationInfo> _elevationCache = {};
  bool _elevationExpanded =
      false; // expand the elevation chart on the nav screen

  /// Current air temperature (°C) for the bottom status bar (Open-Meteo).
  WeatherInfo? _weather;
  Timer? _weatherTimer; // refreshes the weather while navigating

  /// Weather a few km AHEAD along the route (Open-Meteo, sampled at points
  /// along the polyline and merged by severity). Shown in the PiP window so
  /// you can see what's coming while you drive.
  WeatherInfo? _weatherAhead;
  double? _scrubProgress; // 0..1 while the user drags the progress line

  // --- camera alerts (phạt nguội DB) ------------------------------------
  /// Nearest camera AHEAD on the route (from `offline_cameras.dart`), used
  /// for the PiP camera chip + the alert trigger distance.
  CameraAhead? _nextCamera;
  final _cameraGate = _PerSecondGate(); // 1 Hz per-fix check throttle
  final _cameraDedupe = _ZoneDedupe(); // speak each camera far + near only

  /// All bundled cameras, shown as a map layer when [cameraAlerts] is on.
  List<OfflineCamera> _cameras = [];

  /// True once the camera index load has been requested (one-shot, so the
  /// browse map with camera alerts on still shows cameras — but loaded AFTER
  /// the first build, not at boot).
  bool _camerasRequested = false;

  /// Cameras shown on the nav map — bounded to NEAR-THE-CAR while navigating
  /// (see [_refreshRouteCameras]: a whole-route layer of 100+ cameras × 4
  /// native circles each crushed the low-end phone at large zoom). The VOICE
  /// alert (`_checkCameraAhead`) is a separate per-second ahead check.
  List<OfflineCamera> _routeCameras = [];

  // --- simulated drive (testing without GPS — walks the route) ------------
  /// True while the simulated-drive timer is advancing the car along the
  /// route. While on, real GPS fixes are ignored so the sim drives cleanly.
  bool _simulating = false;

  /// Along-route distance (m) the sim has driven so far.
  double _simDist = 0;

  /// 500 ms ticker that advances [_simDist] by ~8 m (~58 km/h).
  Timer? _simTimer;

  /// Recompute [_routeCameras] — CAR-CENTRIC: cameras ahead of the car on
  /// the route, not a whole-route corridor. Called when the route is planned
  /// / re-planned / cleared and when camera alerts toggle on (during nav
  /// `_cameraAheadAsync` keeps it fresh each second).
  ///
  /// Refresh the nav-map camera + sign marker layers. WHILE NAVIGATING these
  /// are bounded to NEAR-THE-CAR only (a handful of markers, refreshed ~5 s) —
  /// a whole long route's route-wide layer is 100+ cameras (each drawn as 4
  /// native maplibre circles) + 2,000+ signs as icon overlays, all held even
  /// off-screen, which crushed the low-end phone at large zoom. During route
  /// PREVIEW / browsing (not navigating) the layers are NOT loaded at all —
  /// that stage is country-zoom and the markers are useless there.
  DateTime? _lastNearbyLayers;
  Future<void> _refreshRouteCameras() async {
    final r = _route;
    if (r == null || r.geometry.length < 2) {
      if (mounted && (_routeCameras.isNotEmpty || _routeSigns.isNotEmpty)) {
        setNavState(() {
          _routeCameras = const [];
          _routeSigns = const [];
        });
      }
      return;
    }
    final pos = _navigating ? _current : null;
    if (pos == null) {
      // Preview/browse: DON'T load the route-wide marker layers (see doc).
      if (mounted && (_routeCameras.isNotEmpty || _routeSigns.isNotEmpty)) {
        setNavState(() {
          _routeCameras = const [];
          _routeSigns = const [];
        });
      }
      return;
    }
    // Markers near the car — BOUNDED so the low-end phone stays smooth: the
    // 1.5 km / 80-sign map layer (and the 5 km uncapped camera layer, each
    // camera drawn as 4 native circles) froze navigation. Now signs are
    // 800 m / 20 and cameras 3 km / 40 (nearest first).
    const Distance d = Distance();
    var cams = await camerasNearPoint(pos, maxDistM: 3000);
    cams.sort(
      (a, b) => d
          .as(LengthUnit.Meter, pos, a.pos)
          .compareTo(d.as(LengthUnit.Meter, pos, b.pos)),
    );
    if (cams.length > 40) cams = cams.sublist(0, 40);
    final signs = await signsNearPoint(pos, maxDistM: 800, max: 20);
    if (!mounted) return;
    setNavState(() {
      _routeCameras = cams;
      _routeSigns = signs;
    });
  }

  /// Load the on-device GraphHopper routing graph — kicked off in the
  /// BACKGROUND right after startup ([initState]) so offline/GraphHopper
  /// routes are ready without a long wait, and re-triggered on demand when
  /// the app actually goes offline mid-session. The graph is a ~450 MB load
  /// (~60 s on low-end phones), so it must never block the first frame:
  /// idempotent (no-ops when already loaded), checks the graph is present
  /// first, defers ~1 s, and the native load itself runs on a background
  /// executor.
  Future<void> _maybeLoadRoutingGraph() async {
    if (OfflineRouter.instance.isLoaded) return;
    if (!await routingGraphPresent()) return;
    final path = await routingGraphPath();
    final t0 = DateTime.now();
    debugPrint('ROUTER: graph load scheduled (background preload)');
    // Small defer so it never competes with the first frames of a route
    // build; the native load itself runs on a background executor.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    debugPrint(
      'ROUTER: graph load STARTING (t+'
      '${DateTime.now().difference(t0).inMilliseconds}ms)',
    );
    final ok = await OfflineRouter.instance.load(path);
    debugPrint(
      'ROUTER: on-device graph loaded=$ok (load took '
      '${DateTime.now().difference(t0).inMilliseconds - 1000}ms)',
    );
  }

  /// Lazily load the offline camera index (once, cached) — only when the
  /// user turns camera alerts ON or a route is set (the map needs it then).
  /// Not at boot, so cold start stays fast.
  Future<void> _ensureCameras() async {
    final cams = await loadOfflineCameras();
    if (!mounted) return;
    setNavState(() => _cameras = cams);
  }

  // --- nav map: 3D perspective tilt (Google-style) ----------------------
  // 3D is an OPTION (toggle in the layers menu) and OFF by default: the
  // tilted camera + building extrusion cost GPU, and on the flat map the
  // pitch alone barely showed. When enabled, [_buildStyleString] also loads
  // the `building-3d` fill-extrusion layer so buildings render with height.
  bool _tilt3d = false; // tilted perspective camera (turn off = flat 2D)
  bool _terrain3d = false; // true 3D terrain relief (needs offline DEM)
  bool _nightMode = false; // night/dark map
  final bool _satellite = false; // satellite imagery basemap (removed toggle)
  bool _showStatusBar = false; // Google-style bottom info bar (default off)

  /// Dark theme for simple nav mode (no map) — toggled on the simple screen.
  bool _simpleDark = false;

  /// Draggable position of the nav auto-center ("my_location") button, in
  /// logical pixels (top-left of the overlay). Null = the default spot
  /// (bottom-right). Session-only for now.
  Offset? _centerBtnOffset;
  NavBarMode _barMode = NavBarMode.time; // bottom slide: time or elevation

  // --- quick POI search (gas / food / hotel / … during navigation) ------
  List<PoiResult> _pois = [];
  PoiType? _poiType;
  PoiResult? _selectedPoi; // tapped POI — shown on the map until "Đi đến"
  bool _poiBusy = false;

  /// Places found by the nav-mode search bar, drawn as markers on the vector
  /// map so the driver can SEE the options ahead (not just the text list).
  /// Ranked by route position (ahead 10–20 km, same side of road first).
  List<PoiResult> _searchResults = [];

  // --- offline POI browse (bundled vietnam_pois.json) --------------------
  List<OfflinePoiCategory>? _offlinePoiCats; // loaded lazily once
  bool _offlinePoiBusy = false;
  String? _offlinePoiCatLoading; // category key currently loading

  // --- nav-map camera follow (drives the auto-center button) -------------
  final VectorNavMapController _vmFollow = VectorNavMapController();

  // --- road info (Overpass) ---
  RoadInfo? _roadInfo;
  bool _roadLoading = false;
  DateTime? _lastRoadQuery;

  // --- trip logging (Google Takeout) ---
  TripLogger? _trip;

  // --- offline mode ---
  // Browse basemap is LOCKED to ONE source so the map never swaps styles when
  // zooming. _tileProvider.source MUST match _tileSource — the tile cache and
  // downloaded regions are keyed by it.
  final String _tileSource = 'carto';
  final OfflineTileProvider _tileProvider = OfflineTileProvider(
    // Keep in sync with [_tileSource] ('carto') — the tile cache and
    // downloaded regions are keyed by this. (A field initializer can't
    // reference _tileSource directly — the implicit_this lint forbids it.)
    source: 'carto',
  );
  bool _offline = false;

  /// Whether to show the transient "Đang ngoại tuyến" banner. Shown briefly
  /// when the app goes offline (or starts offline), then auto-hides after a
  /// few seconds — it's just a heads-up, it adds no ongoing info.
  bool _showOfflineBanner = false;
  Timer? _offlineBannerTimer;
  StreamSubscription<bool>? _connSub;

  /// Debounce for the offline transition. `connectivity_plus` on some ROMs
  /// (e.g. itel) intermittently reports `none` even when the network is up —
  /// without this, `_offline` flaps and the nav map's `vietmapBase` toggles,
  /// which reloads the whole map style on every blip ("the map type keeps
  /// changing"). We only commit to offline after the reading holds ~3 s.
  Timer? _offlineDebounce;

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

  // --- multi-stop plan ---
  final List<TripStop> _stops = [];

  // --- voice: spoken guidance (Bluetooth speaker) + mic commands --------
  final VoiceGuide _voice = VoiceGuide();
  final VoiceCommands _commands = VoiceCommands();
  bool _listening = false;

  /// LIVE recognized text for the mic "listening…" banner (partial results
  /// stream in while the user speaks). Cleared when the session ends.
  String _voiceText = '';

  /// True while a listening/command banner should be shown (listening state
  /// OR the just-recognized text to confirm what was heard).
  bool _voiceBannerVisible = false;
  Timer? _voiceBannerTimer;

  /// Always-on wake-word listening ("NavBridge, …") — toggled by a LONG-PRESS
  /// on the mic button. Keeps the recognizer running and only acts when the
  /// wake word is heard, so hands-free commands work without touching the map.
  bool _alwaysOnVoice = false;
  bool _voiceOn = true; // spoken turn-by-turn guidance enabled
  bool _spokenFar = false;
  bool _spokenNear = false;
  bool _spokenFinal = false;
  bool _arrivedSpoken = false;
  String? _lastManeuverSig; // icon+road of the maneuver we last announced
  bool _speedingSpoken = false; // overspeed alert already announced (episode)
  DateTime? _lastOverspeedAt; // last overspeed voice alert (60 s cooldown)
  int? _signSpeedLimit; // effective limit from the last speed-limit sign passed
  int?
  _zoneSpeedLimit; // 40 in "khu đông dân cư" (populated) zone; null outside

  // Speed-limit-change announcement state: speak the limit only once it has
  // been stable for ~2 s and not repeated within ~4 s (avoids boundary spam).
  int? _lastSpokenLimit;
  int? _pendingLimit;
  DateTime? _pendingSince;
  DateTime? _lastLimitSpoke;

  /// Effective speed limit: the last speed-limit sign (incl. Waze) or the
  /// populated-area zone the car is in, falling back to the road's
  /// tagged/VN-default limit. This is what overspeed alerts + the speed chip
  /// announce.
  int get _effectiveSpeedLimit =>
      _signSpeedLimit ?? _zoneSpeedLimit ?? _roadInfo?.speedLimit ?? 0;

  /// Reset the sign/zone speed-limit + limit-announce state for a fresh
  /// navigation or simulation session.
  void _resetSignSpeed() {
    _signSpeedLimit = null;
    _zoneSpeedLimit = null;
    _lastSpokenLimit = null;
    _pendingLimit = null;
    _pendingSince = null;
    _lastLimitSpoke = null;
  }

  /// Push the floating widget's state to the overlay engine: the next-maneuver
  /// snippet (Vietmap-Live style), the speed limit and the next camera — all
  /// computed HERE, so the overlay engine loads NO offline layers (that was
  /// the freeze). The widget is NEVER auto-hidden (removed the old
  /// zoom/radar-based hide — it made the traffic sign vanish while driving).
  ///
  /// While NOT navigating (e.g. the user runs Google Maps underneath), it
  /// still computes the CURRENT STREET's posted limit + nearest camera from
  /// the live GPS fix, so the floating widget works standalone: speed + limit
  /// + camera on top of any app. Cheap: deduped, ~1/s.
  Future<void> _syncOverlayVisibility() async {
    // HARD 1 Hz gate (see field doc) — this is called from onPositionChanged
    // + the nav-map controller at far above 1 Hz during gestures.
    final now = DateTime.now();
    if (_lastOverlaySync != null &&
        now.difference(_lastOverlaySync!) < const Duration(seconds: 1)) {
      return;
    }
    _lastOverlaySync = now;
    double zoom = 19.0;
    try {
      zoom = _navigating ? _vmFollow.zoom : _map.camera.zoom;
    } catch (_) {
      zoom = 19.0;
    }
    final nav = _navigating ? _progress : null;
    // Limit: the effective limit while navigating; otherwise the street's
    // posted limit at the current GPS position (standalone widget).
    var limit = _effectiveSpeedLimit;
    if (limit <= 0) {
      final cur = _current ?? _origin;
      if (cur != null) {
        try {
          limit = await speedLimitAt(cur) ?? 0;
        } catch (_) {
          limit = 0;
        }
      }
    }
    // Every camera within 600 m of the car (the user: "camera should also
    // show all in range 600m").
    final cameraMeters = await _standaloneCameraMeters();

    final signChips = await _standaloneSignAhead();
    final speedMps = _simulating ? 16.0 : _lastSpeedMps;
    final speedKmh = speedMps * 3.6;

    syncOverlayState(
      zoom: zoom,
      radarOn: radarOn,
      satelliteOn: _satelliteOn,
      // Auto-hide ONLY while actively navigating in NavBridge — over Google
      // Maps / browsing the bubble must stay visible (see syncOverlayState).
      navigating: _navigating,
      maneuver: nav == null
          ? null
          : OverlayManeuver(nav.iconCode, nav.meter, nav.nextText),
      limit: limit > 0 ? limit : null,
      // Always send the list (even empty) so the overlay CLEARS a stale
      // camera chip once the car is out of range — not just when there's one.
      cameras: cameraMeters,
      speedKmh: speedKmh,
      signs: signChips.isEmpty ? null : signChips,
    );
  }

  /// The SINGLE sign the floating widget shows — the sign NEAREST ON THE
  /// ROUTE ahead while navigating (cấm rẽ / quay đầu / vượt prioritized), or
  /// the most important sign near the car when standalone over another app.
  Future<List<OverlaySign>> _standaloneSignAhead() async {
    final cur = _current ?? _origin;
    if (cur == null) return const [];
    try {
      final geometry = _route?.geometry ?? const [];
      if (_navigating && geometry.length >= 2) {
        final ahead = await signsAheadOnRoute(
          cur,
          geometry,
          maxAheadMeters: 800,
        );
        final best = bestSignAhead(ahead);
        if (best == null) return const [];
        return [
          OverlaySign(
            best.sign.kind.key,
            best.sign.value,
            best.sign.name,
            best.routeMeters.round(),
          ),
        ];
      }
      final chips = await signsForWidgetChips(cur, maxDistM: 800, max: 1);
      return [
        for (final (s, m) in chips) OverlaySign(s.kind.key, s.value, s.name, m),
      ];
    } catch (_) {}
    return const [];
  }

  /// ALL camera distances (metres) within 600 m of the live position (the
  /// floating widget shows every camera it approaches). Bbox pre-filter so a
  /// dense nationwide DB only scans nearby cameras.
  Future<List<int>> _standaloneCameraMeters() async {
    final cur = _current ?? _origin;
    if (cur == null) return const [];
    try {
      return await camerasForWidgetChips(cur, maxDistM: 600);
    } catch (_) {}
    return const [];
  }

  double _lastGpsAccuracy = 0; // latest GPS fix accuracy (m) → Kalman noise
  bool _gpsWeakSpoken = false; // low-GPS alert announced (episode)
  DateTime? _lastGpsWeakAt; // last low-GPS voice alert (60 s cooldown)
  DateTime? _lastReRoute; // cooldown for off-route re-routing

  // --- online GPS road-snapping (OSRM match) + off-route timing ----------
  final List<LatLng> _gpsWindow = []; // rolling trace for /match
  DateTime? _lastGpsMatch; // throttle: match at most every 5 s
  DateTime? _lastGpsFixTime; // diagnostic: measure the real fix rate
  double _lastSpeedMps = 0;
  DateTime? _offRouteSince; // when the car first went >50 m off-route
  DateTime? _lastNetMatch; // throttle: network snap at most every 1 s
  DateTime? _netOffSince; // when the car first hit a road NOT on the route

  // --- road signs (stop / give-way / traffic lights) -------------------
  List<RoadSign> _routeSigns = []; // map layer: signs near the route
  final _signGate = _PerSecondGate(); // 1 Hz per-fix check throttle
  final _signDedupe = _ZoneDedupe(); // speak each sign far + near only

  /// Latest NETWORK-matching verdict (see [_networkMatch]): true = the car's
  /// nearest road IS part of the route. Trusted by the raw off-route check in
  /// [_handleNav] only while fresh (<2 s) — lets a snapped-on-route fix
  /// suppress false reroutes without ever blocking a real one.
  bool _netOnRoute = false;

  // --- rain radar + weather-satellite overlay (RainViewer) ------------
  RadarData? _radar; // fetched frame index (cached ~5 min)
  DateTime? _radarFetchedAt;
  bool _radarLoading = false;
  int _radarFrame = 0; // selected frame within [_radarFrames]
  bool _satelliteOn = false; // weather-satellite (infrared clouds) layer
  int _satelliteFrame = 0; // selected frame within [_satelliteFrames]
  bool _rainAheadSpoken = false; // rain-ahead voice dedupe per nav session

  // --- wrong-way (inverse) detection -------------------------------
  /// Last RAW GPS fix — used to compute the travel heading for wrong-way
  /// detection (consecutive fixes are more reliable than GPS heading).
  LatLng? _lastFixPos;

  /// When the car started driving AGAINST the route direction (null = fine).
  DateTime? _wrongWaySince;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Preload the on-device GraphHopper routing graph in the BACKGROUND right
    // after start, so an offline / GraphHopper route build never stalls
    // waiting for the ~450 MB graph. Safe for cold start: [_maybeLoadRoutingGraph]
    // is idempotent, checks the graph is present before touching disk, defers
    // ~1 s, and the native load runs on a background executor.
    unawaited(_maybeLoadRoutingGraph());
    // Load saved quick destinations (home / work) for one-tap navigation.
    unawaited(QuickPlaces.instance.load());
    // Picture-in-Picture (Part C): wire up the native PiP-mode callback and
    // swap to the compact layout whenever the OS PiP window appears.
    PipService.instance.init();
    PipService.instance.isPipMode.addListener(_onPipChanged);

    _autoConnect = BleAutoConnectService(
      clock: _clock,
      mapClock: _mapClock,
      onDeviceConnected: (device) {
        if (!mounted) return;
        final isMap = _isMapDisplay(device);
        setState(() {
          if (isMap) {
            _mapStatus = 'connected';
            _sendMapRoute();
            final nav = _progress;
            if (nav != null) _sendToMap(nav);
          } else {
            _clockStatus = 'connected';
          }
        });
      },
    );
    _autoConnect.init();

    _clockSub = _clock.linkStream.listen((l) {
      if (!mounted) return;
      setState(() {
        _clockStatus = switch (l) {
          ClockLink.connected => 'connected',
          ClockLink.connecting => 'connecting',
          ClockLink.off => 'off',
        };
      });
    });
    _mapClockSub = _mapClock.linkStream.listen((l) {
      if (!mounted) return;
      setState(() {
        _mapStatus = switch (l) {
          ClockLink.connected => 'connected',
          ClockLink.connecting => 'connecting',
          ClockLink.off => 'off',
        };
      });
    });
    // ESP32 GPS bridge: subscribe to the board's GPS broadcast — the compact
    // AA55 binary frame (current protocol) + legacy raw NMEA. Fixes flow
    // through the same pipeline as the phone GPS (ESP-first).
    _mapGpsSub = _mapClock.gpsNmeaStream.listen(_onEspNmea);
    _mapGpsFrameSub = _mapClock.gpsFrameStream.listen(_onEspGpsFrame);
    // Nav vector-map zoom → floating-widget auto-hide. The nav map reports
    // its zoom through this controller; a ChangeNotifier listener here means
    // a zoom-out hides the widget even while following (no GPS fix needed).
    _vmFollow.addListener(_syncOverlayVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      debugPrint(
        'STARTUP: first frame at t+'
        '${DateTime.now().difference(_appStart).inMilliseconds}ms',
      );
      if (await _requestPermission()) _startGps();
      // NOTE: the app boots ONLINE-FIRST — routing stays on the fast online
      // OSRM/Vietmap path. The heavy offline camera index is NOT preloaded
      // here (see [_ensureCameras]); it loads lazily when the user turns
      // camera alerts on. The GraphHopper routing graph, however, is already
      // loading in the background from initState ([_maybeLoadRoutingGraph]),
      // so a forced-offline / graphhopper route is ready without a long wait.
    });
    _connSub = onlineStream().listen((online) {
      _applyConnectivity(online);
    });
    isOnline().then((on) {
      if (!mounted) return;
      _applyConnectivity(on);
    });
    // Restore the persisted offline/online mode + data-source choice + the
    // navigation preferences (vehicle / geocoder / routing engine / smooth
    // camera).
    loadSettings().then((s) {
      if (!mounted) return;
      forceOffline = s.forceOffline;
      dataSource = s.dataSource;
      vehicleType = s.vehicleType;
      geocodingProvider = s.geocodingProvider;
      routingEngine = s.routingEngine;
      smoothCamera = s.smoothCamera;
      simpleMode = s.simpleMode;
      cameraAlerts = s.cameraAlerts;
      gpsFilter = s.gpsFilter;
      voiceVolume = s.voiceVolume;
      radarOn = s.radar;
      wakeWord = s.wakeWord;
      overlayLayout = s.overlayLayout;
      overlayScale = s.overlayScale;
      bleAutoConnect = s.bleAutoConnect;
      lastBleMac = s.lastBleMac;
      lastBleName = s.lastBleName;
      lastBleType = s.lastBleType;
      debugPrint(
        'SETTINGS: cameraAlerts=$cameraAlerts radar=$radarOn '
        '(persisted=$s.cameraAlerts) bleAuto=$bleAutoConnect',
      );
      setState(() => _offline = _offline || forceOffline);
      _flashOfflineBanner();
      // If Bluetooth auto-connect is enabled, start the auto-connect hunt.
      if (bleAutoConnect) {
        _autoConnect.rearm();
        unawaited(_autoConnect.autoConnect());
      }
    });
    // Voice: spoken turn-by-turn (→ Bluetooth speaker) + mic commands.
    // TTS + speech-recognition init is deferred OFF the boot path: binding
    // the Android TTS/STT engines during startup competes with the GPS
    // permission flow + the first map frame for the platform thread on
    // low-end phones. Both are only used once the user navigates / taps the
    // mic — well after this delay — and each init already no-ops safely if it
    // fails. (Always-on voice is user-triggered via the mic long-press, so
    // there's no boot-time listener that needs it earlier.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        _voice.init();
        _commands.init(
          onStatus: (s) {
            // NOTE: do NOT clear [_listening] on 'done'/'notListening' — those
            // fire when each ~1 s recognizer session ends, and the one-shot
            // listen loop restarts it (up to the 60 s budget). Clearing here
            // hid the "Đang nghe…" banner and cancelled the "Không nghe rõ"
            // fallback after the first session.
          },
        );
      });
    });
  }

  /// When the app comes back to the foreground (e.g. after the user enabled
  /// the phone's GPS toggle or granted location permission in system
  /// settings), re-check and restart the GPS stream — otherwise a device with
  /// location services turned off would silently never get a fix.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    Future(() async {
      if (await _requestPermission()) _startGps();
    });
    if (bleAutoConnect && !_clock.isConnected && !_mapClock.isConnected) {
      _autoConnect.rearm();
      unawaited(_autoConnect.autoConnect());
    }
  }

  /// OS PiP window appeared/disappeared → swap between the compact PiP layout
  /// and the full nav UI. (PiP is nav-only; browsing never enters it.)
  void _onPipChanged() {
    if (!mounted) return;
    final pip = PipService.instance.isPipMode.value;
    if (pip == _pipActive) return;
    setNavState(() => _pipActive = pip);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PipService.instance.isPipMode.removeListener(_onPipChanged);
    _vmFollow.removeListener(_syncOverlayVisibility);
    _debounce?.cancel();
    _offlineBannerTimer?.cancel();
    _offlineDebounce?.cancel();
    _voiceBannerTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _startCtrl.dispose();
    _startFocus.dispose();
    _gpsSub?.cancel();
    _connSub?.cancel();
    _voice.stop();
    _commands.stop();
    _autoConnect.dispose();
    // If a trip is still recording when the page is closed, save it.
    final t = _trip;
    if (t != null && t.hasEnoughData) {
      unawaited(saveTrip(t).then((_) {}, onError: (Object _) {}));
    }
    _clockSub?.cancel();
    _mapClockSub?.cancel();
    _mapGpsSub?.cancel();
    _mapGpsFrameSub?.cancel();
    _clock.dispose();
    _mapClock.dispose();
    _map.dispose();
    super.dispose();
  }

  /// Shows the "Đang ngoại tuyến" banner for a few seconds (or right away if
  /// already offline) when connectivity state changes. It's just a transient
  /// heads-up — it provides no ongoing info, so it fades out on its own.
  void _flashOfflineBanner({bool wasOffline = false}) {
    // Only flash when we actually *transitioned into* offline mode, so the
    // banner doesn't keep popping up while we're already offline.
    if (!_offline || wasOffline) return;
    _offlineBannerTimer?.cancel();
    if (!mounted) return;
    setState(() => _showOfflineBanner = true);
    _offlineBannerTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _showOfflineBanner = false);
    });
  }

  /// Commit a connectivity reading to [_offline]. Going ONLINE applies
  /// immediately (safe: restores Vietmap/online basemap right away); going
  /// OFFLINE is debounced ~3 s so a transient `connectivity_plus` `none`
  /// blip (common on the itel ROM) doesn't flip `_offline` → `vietmapBase` →
  /// reload the whole map style back and forth.
  void _applyConnectivity(bool online) {
    if (!mounted) return;
    _offlineDebounce?.cancel();
    if (online) {
      final wasOffline = _offline;
      setState(() => _offline = forceOffline);
      _flashOfflineBanner(wasOffline: wasOffline);
      return;
    }
    // Still offline after 3 s → commit (banner + POI categories + basemap).
    _offlineDebounce = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final wasOffline = _offline;
      setState(() => _offline = true);
      if (_offline) {
        unawaited(_ensureOfflinePoiCats());
        // Going offline means online routing is gone — load the on-device
        // graph so offline routing keeps working.
        unawaited(_maybeLoadRoutingGraph());
      }
      _flashOfflineBanner(wasOffline: wasOffline);
    });
  }

  // ---- UI composition --------------------------------------------------

  /// Composes the page UI. The heavy lifting lives in `modules/nav_build.dart`
  /// (`_buildPipLayout` / `_buildMainLayout`) so the State class stays a thin
  /// shell of state + wiring.
  @override
  Widget build(BuildContext context) {
    if (_pipActive && _navigating) return _buildPipLayout();
    // Simple mode: hide the map — just a big arrow + voice commands.
    if (simpleMode && _navigating) return _buildSimpleNavLayout();
    return _buildMainLayout();
  }
}
