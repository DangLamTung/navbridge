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
import 'dart:math' show max, sin, cos, atan2, sqrt, pow;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
import 'package:navbridge/services/offline_data_updater.dart';
import 'package:navbridge/services/offline_geo.dart';
import 'package:navbridge/services/offline_poi.dart';
import 'package:navbridge/services/offline_road_signs.dart';
import 'package:navbridge/services/offline_speed_limits.dart';
import 'package:navbridge/ui/sign_icons.dart';
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
import 'package:navbridge/core/sign_limit.dart';
import 'package:navbridge/services/quick_places.dart';
import 'package:navbridge/services/osm_api.dart';
import 'package:navbridge/services/search_history.dart';
import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/overpass.dart';
import 'package:navbridge/services/urban_area.dart';
import 'package:navbridge/services/overlay_visibility.dart';
import 'package:navbridge/services/overlay_widget.dart' show startOverlay;
import 'package:navbridge/services/radar.dart';
import 'package:navbridge/services/route_export.dart';
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/services/sound_alerts.dart';
import 'package:navbridge/core/trip_plan.dart';
import 'package:navbridge/ui/arrival_card.dart';
import 'package:navbridge/ui/cctv_icon.dart';
import 'package:navbridge/ui/vector_nav_map.dart';
import 'package:navbridge/services/vietmap_api.dart';
import 'package:navbridge/services/vietmap_config.dart';
import 'package:navbridge/pages/vietmap_nav_screen.dart';
import 'package:navbridge/services/ai_assistant.dart';
import 'package:navbridge/services/api_notice.dart';
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
import 'package:navbridge/ui/recent_searches_list.dart';
import 'package:navbridge/ui/route_preview_card.dart';
import 'package:navbridge/ui/search_pill.dart';
import 'package:navbridge/ui/speed_dial.dart';
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

  /// Rebuild when the search fields gain / lose focus — the "previous
  /// searches" history is shown only while a field is focused and empty.
  void _onSearchFocusChanged() {
    if (mounted) setNavState(() {});
  }

  /// Rebuild when the recent-search history changes (entry added / removed,
  /// or loaded from disk after the first frame).
  void _onRecentSearchesChanged() {
    if (mounted) setNavState(() {});
  }

  /// Generation counter so a slow in-flight autocomplete response never
  /// overwrites a newer search (any response with a stale seq is discarded).
  int _searchSeq = 0;

  /// Guards place-detail resolution on selection (Google/Vietmap) against
  /// re-entrant taps firing duplicate API transactions.
  bool _resolvingSuggestion = false;

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

  /// Last-known GPS position, used to open the nav map centered on the
  /// driver's current place (instead of a fixed HCMC fallback) before the
  /// first live fix arrives.
  LatLng? _initialCenter;

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
  StreamSubscription<ClockLink>? _mapClockSub;
  StreamSubscription<String>? _mapGpsSub;
  StreamSubscription<Uint8List>? _mapGpsFrameSub;
  bool _navigating = false;

  /// True while the OS Picture-in-Picture window is on screen (nav only). When
  /// set, the page renders a compact PiP layout so the big banner/controls
  /// don't overflow the tiny floating window.
  bool _pipActive = false;
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

  /// Cameras shown on the BROWSE map — bounded to NEAR-THE-USER only (NOT
  /// all ~70k nationwide markers, which crushed the low-end phone while
  /// browsing / right after finding a route). Refreshed when the user moves
  /// a couple of km (see [_refreshNearCameras]).
  List<OfflineCamera> _nearCameras = [];

  /// Road signs shown on the BROWSE map — same near-user bounding as
  /// [_nearCameras], drawn as real sign icons (cấm vượt / STOP / khu dân cư …)
  /// while browsing, not only during navigation.
  List<RoadSign> _nearSigns = [];

  /// Center of the last near-camera/sign refresh — the lists only recompute
  /// once the user has moved a couple of km, so a 1 Hz GPS fix never rescans.
  LatLng? _nearCamCenter;

  /// Current browse-map zoom — drives marker DENSITY (fewer when zoomed out)
  /// and hides cameras when zoomed in further.
  double _cameraZoom = 13;

  /// True once the camera index load has been requested (one-shot, so the
  /// browse map with camera alerts on still shows cameras — but loaded AFTER
  /// the first build, not at boot).
  bool _camerasRequested = false;

  /// Cameras shown on the nav map — bounded to NEAR-THE-CAR while navigating
  /// (see [_refreshRouteCameras]: a whole-route layer of 100+ cameras × 4
  /// native circles each crushed the low-end phone at large zoom). The VOICE
  /// alert (`_checkCameraAhead`) is a separate per-second ahead check.
  List<OfflineCamera> _routeCameras = [];

  /// Last time [_refreshRouteCameras] was throttled to ~1 s (see
  /// `nav_navigation.dart`) so the near-car camera/sign layer stays a handful
  /// of markers without re-querying the route every GPS fix.
  DateTime? _lastNearbyLayers;

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
  /// Refresh the nav-map camera + sign marker layers.
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

    // Fetch all cameras and signs along the entire route!
    // This allows the browse/preview map to show the route's signs and cameras
    // everywhere, and we vary density by zoom level.
    final routeCams = await camerasNearRoute(r.geometry);
    final routeSigns = await signsNearRoute(r.geometry, corridorMeters: 200);

    if (!mounted) return;

    setNavState(() {
      _routeCameras = routeCams;
      // Repeat speed signs of the SAME limit collapse to ONE icon per stretch
      // (they occupy the front of the priority list and crowded the map); the
      // freed slots go to the other kinds. Display only — the limit itself
      // comes from the sign index, not this list.
      _routeSigns = collapseRepeatedSpeedSigns(routeSigns);
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

  /// Lazily prime the offline camera index (once, cached) — only when the
  /// user turns camera alerts ON or a route is set (the map needs it then).
  /// Not at boot, so cold start stays fast. Also refreshes the bounded
  /// browse-map near-camera layer.
  Future<void> _ensureCameras() async {
    await loadOfflineCameras(); // prime the cached loader
    await _refreshNearCameras();
  }

  /// Refresh the BROWSE-map camera layer: only cameras within ~6 km of the
  /// user (capped at 120 markers) instead of all ~70k nationwide. Throttled
  /// to once per couple of km of movement so a 1 Hz GPS fix never rescans.
  Future<void> _refreshNearCameras([LatLng? target]) async {
    final pos = target ?? _current;
    if (pos == null) return;
    final last = _nearCamCenter;
    if (last != null) {
      final dLat = last.latitude - pos.latitude;
      final dLng = last.longitude - pos.longitude;
      if (dLat * dLat + dLng * dLng < 0.02 * 0.02) return; // ~2 km
    }
    _nearCamCenter = pos;
    final near = await camerasNearPoint(pos, maxDistM: 6000);
    final nearSigns = await signsNearPoint(pos, maxDistM: 6000, max: 120);
    if (!mounted) return;
    // Nearest-first so zoom density culling keeps the closest cameras.
    const Distance d = Distance();
    near.sort(
      (a, b) => d
          .as(LengthUnit.Meter, pos, a.pos)
          .compareTo(d.as(LengthUnit.Meter, pos, b.pos)),
    );
    final capped = near.length > 120 ? near.sublist(0, 120) : near;
    setNavState(() {
      _nearCameras = capped;
      // The browse map is an AREA view: repeat speed signs collapse to the one
      // that applies where the car is, so the marker budget goes to the other
      // kinds (cấm rẽ / quay đầu / cấm vượt / khu dân cư / STOP).
      _nearSigns = keepNearestSpeedSign(collapseRepeatedSpeedSigns(nearSigns));
    });
  }

  // --- nav map: 3D perspective tilt (Google-style) ----------------------
  // 3D is an OPTION (toggle in the layers menu) and OFF by default: the
  // tilted camera + building extrusion cost GPU, and on the flat map the
  // pitch alone barely showed. When enabled, [_buildStyleString] also loads
  // the `building-3d` fill-extrusion layer so buildings render with height.
  bool _tilt3d = false; // tilted perspective camera (turn off = flat 2D)
  bool _terrain3d = false; // true 3D terrain relief (needs offline DEM)
  bool _nightMode = false; // night/dark map
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

  /// Where the car was at [_lastRoadQuery]. The road (and therefore the
  /// displayed/announced limit) must be re-resolved when the car MOVES onto a
  /// different street, not merely when 2 s have passed — see [_refreshRoad].
  LatLng? _lastRoadQueryPos;

  /// True while the Waze segment correction is in flight. Its street name is
  /// read from a module-global (`lastWazeStreetName`) that the NEXT segment
  /// lookup overwrites, so two overlapping corrections would pair one
  /// segment's limit with another segment's street. Re-entry is refused.
  bool _wazeCorrecting = false;

  // --- trip logging (Google Takeout) ---
  TripLogger? _trip;

  // --- offline mode ---
  // Basemap layer is chosen from the "Lớp bản đồ" menu. The tile cache +
  // downloaded regions are keyed by the ACTIVE source; the provider is
  // recreated per switch so each layer caches under its own folder and styles
  // never mix.
  String _tileSource = 'osm';
  OfflineTileProvider _tileProvider = OfflineTileProvider(source: 'osm');
  bool _offline = false;

  /// Whether to show the transient "Đang ngoại tuyến" banner. Shown briefly
  /// when the app goes offline (or starts offline), then auto-hides after a
  /// few seconds — it's just a heads-up, it adds no ongoing info.
  bool _showOfflineBanner = false;
  Timer? _offlineBannerTimer;
  StreamSubscription<bool>? _connSub;
  void Function()? _apiNoticeListener;

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
    'carto-light':
        'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
    'carto-dark': 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
    'topo': 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
    'esri':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'esri-street':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
    // Vietmap layers need the tile key (--dart-define=VIETMAP_TILE_KEY).
    // Without it their URLs carry `?apikey=` and every tile 403s, so the
    // menu only lists them when real keys were compiled in (see below).
    'vietmap': VietmapConfig.mapTiles,
    'vietmapsat': VietmapConfig.satelliteTiles,
    'vector':
        'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
  };

  /// Set the active online basemap layer directly (from the "Lớp bản đồ"
  /// menu). The local tile server sends a proper User-Agent and re-encodes
  /// every tile to PNG, so OSM/CARTO/ESRI all load even on MapLibre builds
  /// that reject the provider's raw HTTP tiles.
  void _setTileSource(String next) {
    if (_tileSource == next) return;
    setNavState(() {
      _tileSource = next;
      _tileProvider = OfflineTileProvider(source: next);
    });
  }

  // --- multi-stop plan ---
  final List<TripStop> _stops = [];

  // --- voice: spoken guidance (Bluetooth speaker) + mic commands --------
  VoiceGuide get _voice => VoiceGuide.instance;
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

  /// Route distance (m) to the speed sign behind [_signSpeedLimit]; 0 = that
  /// sign is at/behind the car, i.e. the value is IN FORCE. The app adopts a
  /// sign up to 400 m BEFORE it is reached (`nav_signs.dart`), so while this is
  /// > ~50 m the value is still UPCOMING and must never be announced with the
  /// pre-recorded "hiện tại" clip.
  double _signAheadM = 0;

  /// Road NAME the [_signSpeedLimit] was posted on. A speed sign applies only
  /// to its own road — once the car turns onto a different road the sign no
  /// longer applies and the chip falls back to that road's own limit (without
  /// this, the PREVIOUS street's sign value stuck after a turn).
  String? _signSpeedLimitRoad;
  bool _motorwayWarned = false; // xe mô tô cấm cao tốc — warn once per entry
  bool _fuelWarned = false; // long fuel gap ahead — warn once per gap
  Timer? _fuelTimer; // periodic fuel-gap watch while navigating

  // Speed-limit-change announcement state: speak the limit only once it has
  // been stable for ~2 s and not repeated within ~4 s (avoids boundary spam).
  int? _lastSpokenLimit;
  int? _pendingLimit;
  DateTime? _pendingSince;
  DateTime? _lastLimitSpoke;

  /// Posted limit from the last speed-limit sign, but capped by the VEHICLE's
  /// statutory class default. OSM/DATMAP/Waze speed signs carry a CAR limit,
  /// so a motorbike/truck must never inherit a car's 80 km/h posted value
  /// (Thông tư 38/2024/TT-BGTVT); a posted sign only ever TIGHTENS their
  /// class ceiling — never lifts it.
  int? get _vehicleCappedSignLimit {
    final sign = _signSpeedLimit;
    if (sign == null || sign <= 0) return null;
    if (vehicleType == 'car') return sign;
    final hw = _roadInfo?.highway ?? '';
    // If the road type isn't known yet, don't just inherit the (car) sign
    // value — cap it against the vehicle's highest statutory default so a
    // motorbike/truck never rides at a car's 80 for a few seconds while the
    // road lookup catches up. Once the highway is known [effectiveLimit]
    // refines it.
    final capped = effectiveLimit(
      hw.isEmpty ? 'unclassified' : hw,
      vehicle: vehicleType,
      taggedKmh: sign,
    );
    return capped > 0 ? capped : null;
  }

  /// Effective speed limit: the last speed-limit sign that is IN FORCE
  /// (vehicle-capped and still on the road it was posted on), else the road's
  /// own tagged / VN-statutory class value. This is what overspeed alerts + the
  /// speed chip announce.
  ///
  /// There is deliberately no third layer any more: the built-up "khu đông dân
  /// cư" zone was removed with the boundary signs it came from (see
  /// [droppedSignKinds]). What that costs: on a rural highway crossing a town
  /// (e.g. QL20 after Đèo Mimosa) the road class still reads high and only a
  /// real posted sign brings it down. What it buys back: one fewer source that
  /// could silently rewrite the limit — the boundary cap never fired on any
  /// recorded drive and contradicts the posted segment value 39% of the time it
  /// does land on one.
  int get _effectiveSpeedLimit => _effectiveLimit.limit;

  /// Short badge naming WHERE the displayed limit came from — shown under the
  /// dial in the floating widget and the nav chip. 'SIGN' when a posted sign is
  /// in force, else the layer behind the road value ('WAZE' segment, 'WAZE pt',
  /// 'VIETMAP', 'OSM' maxspeed, 'CITY' built-up rule, 'CLASS' default).
  String get _limitSourceLabel {
    if (_effectiveLimit.source == 'sign') return 'SIGN';
    return switch (_roadInfo?.src) {
      'segment' => 'WAZE',
      'waze' => 'WAZE pt',
      'vietmap' => 'VIETMAP',
      'osm' => 'OSM',
      'city' => 'CITY',
      _ => 'CLASS',
    };
  }

  /// True once the emulator-replay harness has started navigation.
  bool _autoSimStarted = false;

  /// EMULATOR-REPLAY HARNESS — active only when the app is built with
  /// `--dart-define=SIM_ROUTE=lat,lng` (String.fromEnvironment is compiled in,
  /// so a normal build has an empty string and this returns immediately).
  ///
  /// It waits for the first GPS fix, plans a route to that point and starts
  /// navigation, then prints `AUTOTEST: navigation STARTED` — the marker
  /// [tool/emulator_gps_replay.py] waits for before pushing the recorded track.
  /// That is what lets a recorded drive be replayed against the real limit
  /// chain (road lookup → posted-limit layer → sign adoption → announcements)
  /// without driving or touching the UI.
  void _maybeAutoSim() {
    const spec = String.fromEnvironment('SIM_ROUTE');
    if (spec.isEmpty) return;
    final parts = spec.split(',');
    if (parts.length != 2) return;
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) return;
    debugPrint('AUTOTEST: sim route armed → $lat,$lng');
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_autoSimStarted || _current == null) return;
      _autoSimStarted = true;
      t.cancel();
      unawaited(() async {
        await _planToPoint('sim', lat, lng);
        // Let the route build (OSRM round-trip or the offline graph).
        for (var i = 0; i < 30 && mounted && _route == null; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (!mounted) return;
        _startNavigation();
        debugPrint('AUTOTEST: navigation STARTED');
      }());
    });
  }

  /// True when the effective limit comes from a sign the car has NOT reached
  /// yet (adopted early), so it is the NEXT limit rather than the current one.
  bool get _limitIsUpcoming =>
      _effectiveLimit.source == 'sign' && _signAheadM > kSignReachedM;

  /// Effective limit + which layer supplied it — 'sign' (posted sign /
  /// Waze-DATMAP point, vehicle-capped) or 'road' (the road's own tagged /
  /// statutory class default). The source is recorded in the trip log so a
  /// spoken-vs-road limit mismatch can be diagnosed OFFLINE from a real drive
  /// instead of guessed at.
  ({int limit, String source}) get _effectiveLimit {
    // A speed-limit sign is only authority over the road's own value once the
    // car is AT it AND still on the road it was posted on — see
    // [signLimitInForce]. Before that it is a preview, not the limit: the
    // 09-18 drive rode 4 km at a 60 km/h sign belonging to the street it was
    // still about to join, because a sign adopted early was applied to the
    // current street and, with the road name unknown at adoption, never
    // released.
    final applies = signLimitInForce(
      signValue: _signSpeedLimit,
      signAheadM: _signAheadM,
      signRoad: _signSpeedLimitRoad,
      currentRoad: _roadInfo?.name,
      // A value that came from the segment layer is authority: a sign may only
      // tighten it, never raise it. This is what stops a 60 sign standing on
      // Lũy Bán Bích from lifting Tân Thành / Vườn Lài (50) to 60.
      layerKmh: (_roadInfo?.fromLayer ?? false) ? (_roadInfo!.speedLimit) : 0,
    );
    final sign = applies ? _vehicleCappedSignLimit : null;
    if (sign != null) return (limit: sign, source: 'sign');
    return (limit: _roadInfo?.speedLimit ?? 0, source: 'road');
  }

  /// Reset the sign speed-limit + limit-announce state for a fresh navigation
  /// or simulation session.
  void _resetSignSpeed() {
    _signSpeedLimit = null;
    _signSpeedLimitRoad = null;
    _signAheadM = 0;
    _lastSpokenLimit = null;
    _pendingLimit = null;
    _pendingSince = null;
    _lastLimitSpoke = null;
    _speedChangeDedupe.reset();
    _motorwayWarned = false;
  }

  /// Fetch the last-known GPS position so the nav map opens centered on the
  /// driver's current place (not the fixed HCMC fallback). Best-effort.
  Future<void> _loadInitialCenter() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      if (p != null && mounted) {
        setNavState(() {
          _initialCenter = LatLng(p.latitude, p.longitude);
        });
      }
    } catch (_) {
      // Best-effort — fall back to the default center.
    }
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
    // posted limit at the current GPS position, vehicle-capped (standalone
    // widget over another app).
    var limit = _effectiveSpeedLimit;
    if (limit <= 0) {
      final cur = _current ?? _origin;
      if (cur != null) {
        try {
          final raw = await speedLimitAt(cur) ?? 0;
          limit = vehicleType == 'car'
              ? raw
              : raw > 0
              ? effectiveLimit(
                  _roadInfo?.highway ?? 'unclassified',
                  vehicle: vehicleType,
                  taggedKmh: raw,
                )
              : 0;
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
      limitSrc: _limitSourceLabel,
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
  bool _isRerouting = false; // in-flight route recalculation lock
  DateTime? _lastRerouteSpeech; // throttle reroute voice announcements

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
  final _speedChangeDedupe = _ZoneDedupe(); // warn once per speed-drop sign

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

  /// LAST CONFIRMED rain state AT THE CAR (null = not known yet). The voice
  /// only speaks on a CHANGE (dry→rain / rain→dry) — a periodic "it is still
  /// raining" is noise (user: "periodic update when it raining all over place
  /// is not very useful, what better is when is it stop/start rain").
  bool? _rainingHere;

  /// Consecutive DRY samples (~3 min apart) — the STOP announcement waits for
  /// two so a lull between two showers is not called "tạnh mưa".
  int _dryStreak = 0;

  /// Throttle between rain announcements, so a flickering forecast can't flap
  /// between "bắt đầu mưa" and "tạnh mưa" every refresh.
  DateTime? _lastRainSpoke;

  /// "Sắp hết mưa …" already announced for this rain episode — the route
  /// AHEAD is dry while it is still raining here (user: "should be will stop
  /// raining in .. time when the path ahead clear or it about to stop rain").
  bool _rainEndSpoken = false;

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
    // Surface one-shot provider notices (e.g. "Google Places quota exceeded")
    // as a SnackBar so the driver knows the source is limited.
    _apiNoticeListener = () {
      final msg = apiNotice.value;
      if (msg == null || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final m = apiNotice.value;
        if (m == null) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(m),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        apiNotice.value = null;
      });
    };
    apiNotice.addListener(_apiNoticeListener!);
    // Preload the on-device GraphHopper routing graph in the BACKGROUND right
    // after start, so an offline / GraphHopper route build never stalls
    // waiting for the ~450 MB graph. Safe for cold start: [_maybeLoadRoutingGraph]
    // is idempotent, checks the graph is present before touching disk, defers
    // ~1 s, and the native load runs on a background executor.
    unawaited(_maybeLoadRoutingGraph());
    // Warm up the AI assistant (encrypted key read, memory + system prompt)
    // in the background so the first question in a session answers fast
    // instead of paying for the slow Keystore/asset IO on first ask().
    unawaited(AiAssistant.instance.warmup());
    // Auto-update the offline camera / road-sign data from the configured
    // server (DATA_URL) in the background — no APK needed to refresh these
    // DBs. No-op (and no network) when DATA_URL is not set.
    unawaited(OfflineDataUpdater.instance.autoUpdate());
    // Emulator-replay harness: with --dart-define=SIM_ROUTE=lat,lng the app
    // plans that route and starts navigation by itself once a GPS fix exists,
    // so tool/emulator_gps_replay.py can exercise the whole limit chain (road
    // lookup, layer lookup, sign adoption, announcements) with no UI driving.
    // No define in a normal build → the constant is empty and this is a no-op.
    _maybeAutoSim();
    // Auto-show the floating speed/limit widget if the user left it enabled —
    // it runs in its own engine and keeps working over other apps when this
    // app is backgrounded. Best-effort; a missing permission just no-ops.
    if (overlayEnabled) unawaited(startOverlay());
    // Load saved quick destinations (home / work) for one-tap navigation.
    unawaited(QuickPlaces.instance.load());
    // Load the recent-search history so tapping the search field offers the
    // previous places immediately (no typing, no network).
    unawaited(RecentSearches.instance.load());
    RecentSearches.instance.addListener(_onRecentSearchesChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _startFocus.addListener(_onSearchFocusChanged);
    // Picture-in-Picture (Part C): wire up the native PiP-mode callback and
    // swap to the compact layout whenever the OS PiP window appears.
    PipService.instance.init();
    PipService.instance.isPipMode.addListener(_onPipChanged);
    // Open the map centered on the driver's current/last-known place (from
    // the last GPS fix), not the fixed HCMC fallback.
    unawaited(_loadInitialCenter());

    _autoConnect = BleAutoConnectService(
      mapClock: _mapClock,
      onDeviceConnected: (device) {
        if (!mounted) return;
        setState(() {
          _mapStatus = 'connected';
          _sendMapRoute();
          final nav = _progress;
          if (nav != null) _sendToMap(nav);
        });
      },
    );
    _autoConnect.init();

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
      _routeProfile = switch (s.vehicleType) {
        'motorbike' => RouteProfile.motorbike,
        _ => RouteProfile.car,
      };
      geocodingProvider = s.geocodingProvider;
      routingEngine = s.routingEngine;
      smoothCamera = s.smoothCamera;
      simpleMode = s.simpleMode;
      cameraAlerts = s.cameraAlerts;
      navSpeedStyle = s.navSpeedStyle;
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
        '(persisted=${s.cameraAlerts}) bleAuto=$bleAutoConnect',
      );
      setState(() => _offline = forceOffline ? true : _offline);
      if (radarOn) {
        unawaited(_ensureRadar());
      }
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
    if (bleAutoConnect && !_mapClock.isConnected) {
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
    if (_apiNoticeListener != null) {
      apiNotice.removeListener(_apiNoticeListener!);
      _apiNoticeListener = null;
    }
    PipService.instance.isPipMode.removeListener(_onPipChanged);
    _vmFollow.removeListener(_syncOverlayVisibility);
    _debounce?.cancel();
    _offlineBannerTimer?.cancel();
    _offlineDebounce?.cancel();
    _voiceBannerTimer?.cancel();
    _weatherTimer?.cancel();
    _fuelTimer?.cancel();
    _simTimer?.cancel();
    RecentSearches.instance.removeListener(_onRecentSearchesChanged);
    _searchFocus.removeListener(_onSearchFocusChanged);
    _startFocus.removeListener(_onSearchFocusChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _startCtrl.dispose();
    _startFocus.dispose();
    _gpsSub?.cancel();
    _connSub?.cancel();
    _voice.stop();
    _commands.stop();
    // Release the SCREEN wakelock unconditionally.
    //
    // `WakelockPlus.enable()` is called from 3 places when navigation starts /
    // resumes, but `disable()` only existed inside the stop-navigation path —
    // and `dispose()` is NOT that path. Leaving this page any other way
    // (back button, cancelled route, an error path) left the screen pinned ON
    // with no way to release it, which is a large part of the battery gap vs
    // Google Maps. Calling it twice is harmless.
    unawaited(WakelockPlus.disable());
    _autoConnect.dispose();
    // If a trip is still recording when the page is closed, save it.
    final t = _trip;
    if (t != null && t.hasEnoughData) {
      unawaited(saveTrip(t).then((_) {}, onError: (Object _) {}));
    }
    _mapClockSub?.cancel();
    _mapGpsSub?.cancel();
    _mapGpsFrameSub?.cancel();
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
