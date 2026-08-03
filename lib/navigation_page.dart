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
import 'package:permission_handler/permission_handler.dart';

import 'ble_clock.dart';
import 'device_picker.dart';
import 'nav_engine.dart';
import 'nav_protocol.dart';
import 'offline_screen.dart';
import 'offline_router.dart';
import 'offline_tiles.dart';
import 'settings.dart';
import 'osm_api.dart';
import 'osrm.dart';
import 'overpass.dart';
import 'trip_logger.dart';
import 'trip_plan.dart';
import 'trips_screen.dart';
import 'vector_nav_map.dart';
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
  LatLng? _current;
  double? _heading;
  bool _headingUp = true; // rotate map so travel direction points up
  String _carIcon = 'arrow';
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
  };
  static const List<String> _tileLayerNames = ['osm', 'carto', 'topo', 'esri'];
  String _tileSource = 'osm'; // active basemap layer

  // --- multi-stop plan ---
  final List<TripStop> _stops = [];

  // --- voice: spoken guidance (Bluetooth speaker) + mic commands --------
  final VoiceGuide _voice = VoiceGuide();
  final VoiceCommands _commands = VoiceCommands();
  bool _listening = false;
  bool _voiceOn = true; // spoken turn-by-turn guidance enabled
  int _lastMeter = 0;
  bool _spoken300 = false;
  bool _spoken50 = false;
  bool _arrivedSpoken = false;

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
      setState(() => _offline = !online || forceOffline);
    });
    isOnline().then((on) {
      if (!mounted) return;
      setState(() => _offline = !on || forceOffline);
    });
    // Restore the persisted offline/online mode choice.
    loadSettings().then((s) {
      if (!mounted) return;
      forceOffline = s.forceOffline;
      setState(() => _offline = _offline || forceOffline);
    });
    // Voice: spoken turn-by-turn (→ Bluetooth speaker) + mic commands.
    _voice.init();
    _commands.init(onStatus: (s) {
      // Speech session ended (final result / silence / error) → release mic.
      if (s == 'done' || s == 'notListening') {
        _listening = false;
        if (mounted) setState(() {});
      }
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
      _heading = p.heading.isNaN ? null : p.heading;
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
    _maybeSpeakManeuver(nav);
    _refreshRoad(pos);
    _logFix(pos, speedMps);
    _map.move(pos, 17);
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
    final highway = (g['highway'] ?? '') as String;
    if (highway.isEmpty) return null;
    final (label, fallback) = classInfo(highway);
    final ms = (g['maxspeed'] as num?)?.toInt();
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
        var r = await osmAutocomplete(text.trim());
        // Forced-offline + nothing in the offline cache → ask the user
        // whether to go online for this search, instead of silently showing
        // nothing (they want to CHOOSE to go online if needed).
        if (r.isEmpty && forceOffline && !_searchOfflineDeclined) {
          final goOnline = await _confirmGoOnline(
              'Không có kết quả ngoại tuyến cho “${text.trim()}”.');
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
            '$reason\n\nBạn có muốn bật trực tuyến (tạm thời) không?'),
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
      if (mounted) setState(() => _offline = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Đã bật trực tuyến (phiên này)'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    }
    return goOnline == true;
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
    OsrmRoute route;
    try {
      route = await fetchAnyRoute(points);
    } catch (_) {
      // Offline and no offline graph for this route → offer to go online
      // instead of just failing (the user wants to choose if needed).
      if (!forceOffline) rethrow;
      final goOnline = await _confirmGoOnline(
          'Chưa có bộ dữ liệu chỉ đường ngoại tuyến cho tuyến này.');
      if (!goOnline || !mounted) return;
      route = await fetchOsrmRoute(points);
    }
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
    _lastMeter = 0;
    _spoken300 = false;
    _spoken50 = false;
    _arrivedSpoken = false;
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

  // ---- voice: spoken turn-by-turn (Bluetooth speaker) ------------------

  /// Speak the upcoming maneuver at 300 m / 80 m / at the turn itself.
  void _maybeSpeakManeuver(NavProgress nav) {
    if (!_voiceOn || !_voice.ready) return;
    if (nav.iconCode == iconArrive) {
      if (_arrivedSpoken) return;
      _arrivedSpoken = true;
      _voice.speak('Bạn đã đến nơi.');
      return;
    }
    // The engine advanced to a new maneuver when the distance jumps up.
    if (nav.meter > _lastMeter + 50) {
      _spoken300 = false;
      _spoken50 = false;
    }
    _lastMeter = nav.meter;
    final m = nav.meter;
    if (!_spoken300 && m <= 300 && m > 80) {
      _spoken300 = true;
      _voice.speak(_announce(nav, m));
    } else if (!_spoken50 && m <= 80) {
      _spoken50 = true;
      _voice.speak(_announce(nav, m, now: true));
    }
  }

  String _announce(NavProgress nav, int m, {bool now = false}) {
    final verb = switch (nav.iconCode) {
      iconTurnLeft => 'rẽ trái',
      iconTurnRight => 'rẽ phải',
      iconSlightLeft => 'rẽ trái nhẹ',
      iconSlightRight => 'rẽ phải nhẹ',
      iconUturnLeft || iconUturnRight => 'quay đầu',
      iconRoundabout => 'đi theo vòng xuyến',
      _ => 'đi thẳng',
    };
    final road = nav.text.isNotEmpty ? ' vào ${nav.text}' : '';
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Thiết bị này không hỗ trợ nhận diện giọng nói.')));
      }
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Cần quyền micro để điều khiển bằng giọng nói.')));
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
            'Bạn có thể nói: chỉ đường tới chợ Bến Thành, bắt đầu, dừng lại, phóng to, thu nhỏ, bật tiếng, tắt tiếng.');
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
      ..showSnackBar(SnackBar(
        content: Text('Bản đồ: $_tileSource'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ));
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
          // Navigation mode renders a Google-Maps-style offline VECTOR map
          // (MapLibre + bundled HCMC PMTiles); browsing/search keeps the
          // raster map.
          _navigating
              ? VectorNavMap(
                  routeGeometry: route?.geometry ?? const [],
                  routeSteps: route?.steps ?? const [],
                  current: current,
                  heading: _heading,
                  headingUp: _headingUp,
                  carIcon: _carIcon,
                )
              : _buildMap(route, current),
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
                  // Navigation-mode controls: heading-up toggle + fun car
                  // icon cycler (Google-Maps-style rotate + custom marker).
                  if (_navigating)
                    Positioned(
                      right: 10,
                      top: 64,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RoundActionButton(
                            icon: _headingUp
                                ? Icons.explore
                                : Icons.navigation,
                            color: _headingUp
                                ? kAppBlue
                                : const Color(0xFF5F6368),
                            onTap: () =>
                                setState(() => _headingUp = !_headingUp),
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon: Icons.emoji_emotions_outlined,
                            color: const Color(0xFFF4B400),
                            onTap: _cycleCarIcon,
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon:
                                _voiceOn ? Icons.volume_up : Icons.volume_off,
                            color: _voiceOn
                                ? const Color(0xFF34A853)
                                : const Color(0xFF5F6368),
                            onTap: () =>
                                setState(() => _voiceOn = !_voiceOn),
                          ),
                          const SizedBox(height: 8),
                          RoundActionButton(
                            icon: _listening ? Icons.mic : Icons.mic_none,
                            color: _listening
                                ? const Color(0xFFEA4335)
                                : const Color(0xFFF4B400),
                            onTap: _toggleListening,
                          ),
                        ],
                      ),
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
          // Basemap layer (changeable): OSM / CARTO / OpenTopoMap / ESRI
          // satellite. Requests are throttled to the OSM tile policy and
          // auto-fail over; each layer caches under its own folder so styles
          // never mix.
          urlTemplate: _tileLayers[_tileSource],
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
