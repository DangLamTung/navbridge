/// Offline vector navigation map (MapLibre GL), Google-Maps-style.
///
/// Renders the bundled HCMC vector tiles (PMTiles, copied from assets into
/// app storage on first use) with the bundled OSM-Liberty style and local
/// fonts/sprite — so the navigation map is fully offline, crisp at every
/// zoom, and consistent (no tile-source switching).
///
/// Shows the route as a white-cased blue polyline and follows the live
/// position like a normal car navigation map.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import 'osrm.dart';
import 'poi_search.dart';
import 'terrain.dart';
import 'trip_plan.dart';

/// Built-in car marker icons (see assets/offline_map/icons/).
const List<String> kCarIcons = [
  'arrow',
  'car',
  'racecar',
  'taxi',
  'rocket',
  'turtle',
  'scooter',
  'bike',
  'duck',
  'bee',
  'plane',
];

/// Notifies the page about the nav-map camera follow state so it can render
/// the auto-center button in a layer above the platform view (a sibling
/// widget inside the map's Stack is occluded by the MapLibre platform view).
class VectorNavMapController extends ChangeNotifier {
  bool _following = true;
  bool get following => _following;
  VoidCallback? _recenter;

  void attachRecenter(VoidCallback cb) => _recenter = cb;
  void recenter() => _recenter?.call();

  void setFollowing(bool v) {
    if (_following != v) {
      _following = v;
      notifyListeners();
    }
  }
}

class VectorNavMap extends StatefulWidget {
  const VectorNavMap({
    super.key,
    this.routeGeometry = const [],
    this.routeSteps = const [],
    this.routeStartIndex = 0,
    this.current,
    this.bearing,
    this.heading,
    this.headingUp = true,
    this.tilt3D = true,
    this.terrain3D = false,
    this.nightMode = false,
    this.carIcon = 'arrow',
    this.pois = const [],
    this.selectedPoi,
    this.stops = const [],
    this.satellite = false,
    this.controller,
  });

  /// Route polyline to draw (latlong2 points).
  final List<ll.LatLng> routeGeometry;

  /// Route steps (maneuvers) — used for the traffic-colored route and the
  /// intersection (traffic-light) dots.
  final List<OsrmStep> routeSteps;

  /// Index into [routeGeometry] where the DRAWN route starts. The part of the
  /// route already driven (vertices before this) is "consumed" and not drawn,
  /// Google-Maps style. 0 = draw the whole route.
  final int routeStartIndex;

  /// Live position to follow.
  final ll.LatLng? current;

  /// Smoothed route-ahead bearing (0=N) from the nav engine
  /// (`TurnByTurnEngine.routeBearing`) — the direction of the road ahead of
  /// the car, low-pass filtered. Drives both the heading-up camera and the
  /// arrow in north-up mode, replacing the phone compass and the raw
  /// nearest-segment scan (both caused the arrow/camera to flicker).
  final double? bearing;

  /// Heading (degrees, 0=N) from the phone's compass sensor.
  final double? heading;

  /// Rotate the map so the travel direction points up (Google-style).
  final bool headingUp;

  /// Tilted 3D perspective camera (Google-style). Turn off for a flat 2D map.
  final bool tilt3D;

  /// True 3D terrain relief from the offline DEM (bundled `terrain.pmtiles`
  /// or downloaded Terrarium tiles). The `raster-dem` source + `terrain`
  /// style property are injected when enabled; with the tilted camera the
  /// mountains render as real 3D geometry. Off (and no DEM data) → flat map.
  final bool terrain3D;

  /// Night (dark) map mode: dark background + a dim overlay so the map is
  /// easy on the eyes after dark, while the route/arrow (annotations) stay
  /// bright.
  final bool nightMode;

  /// Car marker icon name (from [kCarIcons]).
  final String carIcon;

  /// Nearby POIs to highlight (gas/food/hotel/…) during navigation.
  final List<PoiResult> pois;

  /// The POI the user tapped — the camera centers on it (follow pauses).
  final PoiResult? selectedPoi;

  /// Multi-stop trip waypoints — drawn as numbered markers on the map so the
  /// driver sees where each stop is.
  final List<TripStop> stops;

  /// Satellite imagery basemap (ESRI World Imagery, free) — shows real
  /// terrain, nicer for mountain views than the light vector map. Online
  /// only; falls back to the vector/light map when offline.
  final bool satellite;

  /// Camera-follow controller for the auto-center button (rendered by the
  /// page so it sits above the platform view).
  final VectorNavMapController? controller;

  @override
  State<VectorNavMap> createState() => _VectorNavMapState();
}

class _VectorNavMapState extends State<VectorNavMap>
    with WidgetsBindingObserver {
  MapLibreMapController? _controller;
  String? _styleString;
  String? _styleError;
  /// Parsed nav style with file:// paths resolved — terrain is injected on
  /// top of this per [_buildStyleString].
  Map<String, dynamic>? _baseStyle;
  /// Offline `raster-dem` source (bundled pmtiles or downloaded terrarium
  /// tiles), or null when no DEM data is present.
  Map<String, dynamic>? _demSource;
  Line? _casing;
  Line? _routeLine;
  final List<Line> _trafficLines = [];
  final List<Circle> _trafficLights = [];
  final List<Circle> _poiCircles = [];
  final List<Symbol> _poiSymbols = [];
  String? _lastPoiSig;
  bool _hasPosition = false;
  // Vietmap-style nav camera: start at max zoom with the car centered. The
  // user can pinch to a different zoom — it's adopted (see [_onCamIdle]) so
  // follow keeps the map at the zoom the user chose instead of snapping back
  // to 19 (that's what made it feel "zoom in only").
  double _zoom = 19;
  String? _lastRouteSig;

  /// True when the nav-map tiles (PMTiles) are not on disk yet — either they
  /// were never bundled or the user hasn't downloaded them. Show a prompt to
  /// download instead of a blank/error map.
  bool _mapMissing = false;

  /// Last computed route bearing — reused (instead of the raw phone compass)
  /// when the route geometry is momentarily absent (e.g. during a re-route),
  /// so the camera/arrow never snap to the noisy compass heading.
  double _lastRouteBearing = 0;
  bool _hasRouteBearing = false;

  /// 10 s idle → auto-center back on the car after the user pans away.
  Timer? _recenterTimer;

  /// Camera auto-follow is enabled. Turned off after the user pans/zooms the
  /// map (Vietmap behavior: the map stays where the user left it) and turned
  /// back on by the recenter button or after 10 s of no interaction.
  bool _followEnabled = true;

  /// Screen position (top-left of the arrow) of the car while auto-follow is
  /// paused (user panning/zooming) — projected from the live camera so the
  /// arrow stays glued to the car's real position instead of vanishing.
  Offset? _carScreen;

  /// Projected on-screen positions of the trip stops (marker top-left) —
  /// refreshed alongside [_carScreen] so the stop indicators stay glued to
  /// the map.
  final List<Offset?> _stopScreens = [];

  /// True after the first `resumed` lifecycle event (app launch). Used so the
  /// style-reload self-heal only runs on REAL background→foreground returns.
  bool _resumedOnce = false;

  /// The camera we last requested for the follow ease — used in [_onCamIdle]
  /// to tell our own moves from the user's pan/zoom (no pointer wrapper, so
  /// the platform view keeps full pan + pinch control).
  CameraPosition? _lastFollowCam;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?.attachRecenter(_recenter);
    widget.controller?.setFollowing(true);
    _prepare();
  }

  /// Self-heal: the MapLibre GL surface on the low-end itel can die (the map
  /// renders black while the Flutter UI keeps drawing) after the screen
  /// sleeps or the app is backgrounded. Reloading the style forces the
  /// renderer to re-initialize the GL context, bringing the map back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_resumedOnce) {
      _resumedOnce = true; // first resume = app launch, nothing to heal
      return;
    }
    final ctrl = _controller;
    final style = _styleString;
    if (ctrl != null && style != null && style.isNotEmpty) {
      unawaited(_reloadStyle(ctrl, style));
    }
  }

  /// Copies the bundled PMTiles + sprite + glyphs into app storage (MapLibre
  /// on Android can't read Flutter `asset://` paths, but plain `file://`
  /// paths work), then builds the style with absolute on-device paths so the
  /// navigation map is fully offline.
  Future<void> _prepare() async {
    try {
      final sup = await getApplicationSupportDirectory();
      final dir = Directory('${sup.path}/nav_map');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // --- manifest-driven copy of bundled assets -----------------------
      final manifest =
          jsonDecode(
                await rootBundle.loadString('assets/offline_map/manifest.json'),
              )
              as Map<String, dynamic>;

      final pmtilesFile = File('${dir.path}/${manifest['pmtiles']}');
      if (!pmtilesFile.existsSync()) {
        // The tiles may be bundled OR downloaded on demand (offline screen).
        // Try the bundled copy; if it isn't bundled, the nav map is simply
        // not downloaded yet → the placeholder below is shown instead.
        try {
          final data = await rootBundle.load(
            'assets/offline_map/${manifest['pmtiles']}',
          );
          await pmtilesFile.writeAsBytes(
            data.buffer.asUint8List(),
            flush: true,
          );
        } catch (_) {
          // not bundled — leave it missing
        }
      }
      // Drop any tileset from an older build that is no longer the active
      // one (e.g. the old z14 archive) so device storage isn't wasted.
      for (final old in ['saigon.pmtiles']) {
        final stale = File('${dir.path}/$old');
        if (old != manifest['pmtiles'] && stale.existsSync()) {
          try {
            stale.deleteSync();
            debugPrint('VECTORMAP: removed stale $old');
          } catch (_) {}
        }
      }
      // If after all that there is still no tile source, tell the user to
      // download the nav map (no blank/error map).
      if (!pmtilesFile.existsSync()) {
        debugPrint('VECTORMAP: nav-map tiles not present — download needed');
        if (mounted) setState(() => _mapMissing = true);
        return;
      }

      final spriteDir = Directory('${dir.path}/sprite');
      if (!spriteDir.existsSync()) spriteDir.createSync(recursive: true);
      for (final rel in (manifest['sprite'] as List).cast<String>()) {
        final f = File('${spriteDir.path}/${rel.split('/').last}');
        if (!f.existsSync()) {
          final data = await rootBundle.load('assets/offline_map/$rel');
          await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
      }

      final fontsDir = Directory('${dir.path}/fonts');
      if (!fontsDir.existsSync()) fontsDir.createSync(recursive: true);
      final fonts = (manifest['fonts'] as Map).cast<String, List<dynamic>>();
      for (final entry in fonts.entries) {
        final outDir = Directory('${fontsDir.path}/${entry.key}');
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        for (final rel in entry.value.cast<String>()) {
          final f = File('${outDir.path}/${rel.split('/').last}');
          if (!f.existsSync()) {
            final data = await rootBundle.load('assets/offline_map/$rel');
            await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
        }
      }

      // --- build the style with absolute file:// paths ------------------
      final styleRaw = await rootBundle.loadString(
        'assets/offline_map/nav_style.json',
      );
      final style = jsonDecode(styleRaw) as Map<String, dynamic>;
      final src = style['sources'] as Map<String, dynamic>;
      src['openmaptiles']['url'] = 'pmtiles://file://${pmtilesFile.path}';
      debugPrint('VECTORMAP: vector source -> ${src['openmaptiles']['url']}');
      // Online raster fallback so the nav map shows ANYWHERE while online —
      // the bundled pmtiles only covers HCMC, so outside it the vector source
      // has no tiles (flat gray "no map"). A light CARTO basemap (no labels;
      // the vector layers draw labels) sits above the background and below
      // the vector layers: where vector tiles exist they draw over it,
      // elsewhere the raster shows through. Free, no key.
      src['raster-fallback'] = <String, dynamic>{
        'type': 'raster',
        'tiles': [
          'https://basemaps.cartocdn.com/light_nolabels/{z}/{x}/{y}.png',
        ],
        'tileSize': 256,
        'maxzoom': 20,
        'attribution': '© CARTO © OpenStreetMap',
      };
      final layers = style['layers'] as List<dynamic>;
      final insertAt =
          (layers.isNotEmpty &&
                  layers.first is Map &&
                  (layers.first as Map)['id'] == 'background')
              ? 1
              : 0;
      layers.insert(insertAt, <String, dynamic>{
        'id': 'raster-fallback',
        'type': 'raster',
        'source': 'raster-fallback',
      });
      style['glyphs'] = (style['glyphs'] as String).replaceAll(
        '__NAV_FONTS__',
        fontsDir.path,
      );
      style['sprite'] = (style['sprite'] as String).replaceAll(
        '__NAV_SPRITE__',
        spriteDir.path,
      );
      _baseStyle = style;
      _demSource = await _resolveDemSource();
      debugPrint(
        'VECTORMAP: base style sources=${src.keys.toList()} '
        'layers=${layers.length}',
      );
      if (mounted) setState(() => _styleString = _buildStyleString());
    } catch (e) {
      debugPrint('VECTORMAP: prepare failed: $e');
      if (mounted) setState(() => _styleError = '$e');
    }
  }

  /// Offline DEM source for 3D terrain: a bundled `terrain.pmtiles` wins;
  /// otherwise downloaded Terrarium PNG tiles served straight from disk as a
  /// `file://` raster-dem source. When nothing is on disk yet, fall back to
  /// the LIVE AWS Terrarium DEM (public, no key) so MapLibre's 3D terrain
  /// "just works" whenever the device is online — the offline store is only
  /// needed for fully-offline operation.
  Future<Map<String, dynamic>?> _resolveDemSource() async {
    final pm = await terrainPmtilesPath();
    if (pm != null) {
      return {'type': 'raster-dem', 'url': 'pmtiles://file://$pm'};
    }
    final root = await terrainTilesRoot();
    if (Directory('$root/$kTerrainMinZoom').existsSync()) {
      return {
        'type': 'raster-dem',
        'tiles': ['file://$root/{z}/{x}/{y}.png'],
        'encoding': 'terrarium',
        'tileSize': 256,
      };
    }
    // Online: live public Terrarium DEM (same encoding as the downloaded
    // tiles). This is what makes the ⛰ terrain button useful immediately.
    return {
      'type': 'raster-dem',
      'tiles': [
        'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
      ],
      'encoding': 'terrarium',
      'tileSize': 256,
    };
  }

  /// The style JSON string with (or without) 3D terrain, depending on
  /// [widget.terrain3D] and whether offline DEM data exists.
  String _buildStyleString() {
    if (_baseStyle == null) return '';
    final style = applyTerrainToStyle(
      _baseStyle!,
      _demSource,
      enabled: widget.terrain3D,
    );
    // Satellite basemap: swap the online raster-fallback to ESRI World
    // Imagery (free, no key — real terrain photos, great for mountains).
    // Offline it stays transparent and the vector map shows through.
    final src = style['sources'] as Map<String, dynamic>;
    final fallback = src['raster-fallback'] as Map<String, dynamic>?;
    if (fallback != null) {
      fallback['tiles'] = [
        if (widget.satellite)
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Imagery/MapServer/tile/{z}/{y}/{x}'
        else
          'https://basemaps.cartocdn.com/light_nolabels/{z}/{x}/{y}.png',
      ];
    }
    // Night mode: dark background layer + a semi-transparent black overlay so
    // the map goes dark while the route/arrow (annotations) stay bright.
    final layers = style['layers'] as List<dynamic>;
    if (widget.nightMode) {
      for (final l in layers) {
        if (l is Map && l['id'] == 'background') {
          (l['paint'] as Map<String, dynamic>)['background-color'] = '#0E1116';
        }
      }
      if (!layers.any((l) => l is Map && l['id'] == 'night-overlay')) {
        layers.add(<String, dynamic>{
          'id': 'night-overlay',
          'type': 'background',
          'paint': <String, dynamic>{
            'background-color': '#000000',
            'background-opacity': 0.55,
          },
        });
      }
    } else {
      layers.removeWhere((l) => l is Map && l['id'] == 'night-overlay');
    }
    debugPrint(
      'VECTORMAP: final style sources='
      '${(style['sources'] as Map).keys.toList()} firstLayers='
      '${layers.take(6).map((l) => l is Map ? l['id'] : '?').toList()}',
    );
    return jsonEncode(style);
  }

  Future<void> _addRoute() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final pts = _drawnRoute()
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
    if (pts.length < 2) return;
    // Bold Vietmap-style route: thick white casing under a solid blue line
    // (the navigation route is drawn large so it reads clearly at 320dpi).
    try {
      _casing = await ctrl.addLine(
        LineOptions(geometry: pts, lineColor: '#ffffff', lineWidth: 14),
      );
      _routeLine = await ctrl.addLine(
        LineOptions(geometry: pts, lineColor: '#1A73E8', lineWidth: 10),
      );
      _lastRouteSig = _routeSignature();
    } catch (e) {
      // Style/annotation manager transiently unavailable (e.g. emulator GPU
      // reset) — the route line is re-added on the next style-loaded event.
      debugPrint('VECTORMAP: add route skipped (map reloading): $e');
      _lastRouteSig = null;
    }
  }

  /// The portion of the route still ahead of the car — the part already
  /// driven is "consumed" and not drawn (Google-style). Starts at the car's
  /// snapped position once part of the route is behind it, so the drawn line
  /// begins right at the puck.
  List<ll.LatLng> _drawnRoute() {
    final g = widget.routeGeometry;
    if (g.isEmpty) return g;
    final start = widget.routeStartIndex.clamp(0, g.length - 1);
    if (start <= 0) return g; // full route (nothing consumed yet)
    final c = widget.current;
    if (c != null) {
      return [c, for (var k = start + 1; k < g.length; k++) g[k]];
    }
    return g.sublist(start);
  }

  /// Stable signature of the drawn route: how much has been consumed (start
  /// index) + full geometry length + destination. Changes only when the car
  /// passes a route vertex (more gets consumed) or a brand-new route is set —
  /// NOT every GPS fix (the consumed start point moves continuously and the
  /// drawn line only needs rebuilding when the vertex list actually changes).
  String _routeSignature() {
    final g = widget.routeGeometry;
    if (g.isEmpty) return '';
    final last = g.last;
    return '${widget.routeStartIndex}|${g.length}|'
        '${last.latitude.toStringAsFixed(5)},${last.longitude.toStringAsFixed(5)}';
  }

  /// POI markers (colored dot + name label). Rebuilt when the list changes.
  String _poiSignature(List<PoiResult> pois) =>
      pois.map((p) => '${p.type.key}:${p.lat},${p.lng}:${p.name}').join('|');

  Future<void> _updatePois() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final sig = _poiSignature(widget.pois);
    if (sig == _lastPoiSig) return;
    _lastPoiSig = sig;
    for (final c in _poiCircles) {
      try {
        ctrl.removeCircle(c);
      } catch (_) {}
    }
    for (final s in _poiSymbols) {
      try {
        ctrl.removeSymbol(s);
      } catch (_) {}
    }
    _poiCircles.clear();
    _poiSymbols.clear();
    for (final p in widget.pois) {
      final col = switch (p.type) {
        PoiType.fuel => '#F4B400',
        PoiType.food => '#EA4335',
        PoiType.hotel => '#1A73E8',
        PoiType.atm => '#9334E6',
        PoiType.hospital => '#34A853',
        PoiType.parking => '#5F6368',
      };
      final sel = identical(p, widget.selectedPoi);
      try {
        final c = await ctrl.addCircle(
          CircleOptions(
            geometry: LatLng(p.lat, p.lng),
            circleColor: sel ? '#FF6F00' : col,
            circleRadius: sel ? 16.0 : 9.0,
            circleStrokeColor: sel ? '#202124' : '#FFFFFF',
            circleStrokeWidth: sel ? 3.0 : 2.5,
            circleOpacity: 0.95,
          ),
        );
        _poiCircles.add(c);
        final s = await ctrl.addSymbol(
          SymbolOptions(
            geometry: LatLng(p.lat, p.lng),
            textField: p.name,
            textSize: 12,
            textColor: '#202124',
            textHaloColor: '#FFFFFF',
            textHaloWidth: 1.8,
            textAnchor: 'bottom',
            textOffset: const Offset(0, -0.4),
          ),
        );
        _poiSymbols.add(s);
      } catch (_) {}
    }
  }

  void _updateRoute() {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (_lastRouteSig != _routeSignature()) {
      // Drop the old overlays and rebuild (route change = new geometry).
      for (final l in _trafficLines) {
        ctrl.removeLine(l);
      }
      _trafficLines.clear();
      for (final c in _trafficLights) {
        ctrl.removeCircle(c);
      }
      _trafficLights.clear();
      if (_casing != null) {
        ctrl.removeLine(_casing!);
        _casing = null;
      }
      if (_routeLine != null) {
        ctrl.removeLine(_routeLine!);
        _routeLine = null;
      }
      _addRoute();
      _lastRouteSig = _routeSignature();
    }
  }

  /// Vietmap's SimpleCamera: the map rotates to the ROUTE direction (not the
  /// phone compass), so the road ahead is always vertical in heading-up mode.
  /// The bearing comes from the nav engine ([widget.bearing]) — a smoothed
  /// look-ahead along the route — never the raw phone heading and never a
  /// nearest-segment scan (both made the arrow/camera flicker).
  double _bearing() {
    if (!widget.headingUp) return 0; // north-up
    return _routeBearing();
  }

  /// On-screen puck rotation (viewport-aligned, MapLibre's default). In
  /// heading-up mode the camera bearing already equals the route bearing, so
  /// the puck needs no extra rotation and points straight up (Vietmap). In
  /// north-up mode it rotates to the route bearing to show travel direction.
  /// The phone compass is never used to orient the arrow.
  double _puckRotate() {
    if (!widget.headingUp) return _routeBearing();
    return 0;
  }

  /// Route bearing: the engine-smoothed value from the page ([widget.bearing])
  /// when present, else the last cached value — so a momentary gap in the
  /// route (re-route) never falls back to the noisy compass.
  double _routeBearing() {
    final b = widget.bearing;
    if (b != null) {
      _lastRouteBearing = b;
      _hasRouteBearing = true;
      return b;
    }
    return _hasRouteBearing ? _lastRouteBearing : (widget.heading ?? 0);
  }

  /// 3D perspective angle — Vietmap SimpleCamera.DEFAULT_TILT (50).
  static const double _tilt = 50;

  /// Where the car sits on screen, as a fraction of the visible map height
  /// measured from the camera center. 0 = dead center (the user wants the car
  /// centered; at [_zoom] 19 there's still ~290 m of road visible ahead).
  static const double _carAnchor = 0.0;

  void _followPosition() {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    // User is free on the map (follow paused): leave the map where they put
    // it and keep the car arrow pinned to the car's real screen position.
    if (!_followEnabled) {
      unawaited(_updateCarScreen());
      return;
    }
    // Adopt the live camera zoom (whatever the user pinched to) so follow
    // never forces the zoom back to the initial max.
    final live = ctrl.cameraPosition;
    if (live != null && live.zoom >= 3) _zoom = live.zoom.clamp(3.0, 19.0);
    if (ctrl.isCameraMoving) return;
    final bearing = _bearing();
    final car = ll.LatLng(c.latitude, c.longitude);
    final ahead = _followTarget(car, bearing > 0 ? bearing : 0, _zoom);
    final want = CameraPosition(
      target: LatLng(ahead.latitude, ahead.longitude),
      zoom: _zoom,
      bearing: bearing,
      tilt: widget.tilt3D ? _tilt : 0,
    );
    final last = _lastFollowCam;
    final lastTarget = last == null
        ? null
        : ll.LatLng(last.target.latitude, last.target.longitude);
    final moved = lastTarget == null || _distMeters(lastTarget, ahead) > 1.0;
    final turned = last == null || ((bearing - last.bearing) % 360).abs() > 1.0;
    final zoomChanged = last == null || (want.zoom - last.zoom).abs() > 0.01;
    if (moved || turned || zoomChanged) {
      _lastFollowCam = want;
      _hasPosition = true;
      // Native smooth animation (the Google-Maps / Vietmap approach) — it is
      // automatically cancelled the instant the user touches the map, so a
      // pan / pinch / rotate never fights the follow camera.
      unawaited(
        ctrl.animateCamera(
          CameraUpdate.newCameraPosition(want),
          duration: const Duration(milliseconds: 500),
        ),
      );
    }
  }

  /// Fires when the camera stops moving: either our follow animation finished
  /// (camera sits on [_lastFollowCam] → keep following) or the user
  /// interrupted it with a pan / pinch / rotate. Only a real PAN (the camera
  /// target moved away) pauses follow — a pure rotate / pinch-zoom keeps
  /// following, so the car arrow never vanishes while the driver re-orients
  /// the view. When follow is paused, the arrow is projected to the car's
  /// real on-screen position.
  void _onCamIdle() {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (!_followEnabled) {
      unawaited(_updateCarScreen());
      return;
    }
    final last = _lastFollowCam;
    if (last == null || !_hasPosition) return;
    final cam = ctrl.cameraPosition;
    if (cam == null) return;
    final t = cam.target;
    final targetClose =
        _distMeters(
          ll.LatLng(last.target.latitude, last.target.longitude),
          ll.LatLng(t.latitude, t.longitude),
        ) <
        8;
    if (!targetClose) {
      _userPanned(); // the user dragged the map away
    }
  }

  /// Fires on every camera-ease / gesture frame. While the camera moves, keep
  /// re-projecting the car so the arrow stays glued to the car's REAL on-
  /// screen position (it visibly advances with the car instead of being a
  /// static center dot). Throttled to ~10/s to keep platform-channel calls
  /// cheap.
  DateTime _lastProject = DateTime.fromMillisecondsSinceEpoch(0);

  void _onCamMove(CameraPosition cam) {
    if (widget.current == null || _controller == null) return;
    final now = DateTime.now();
    if (now.difference(_lastProject).inMilliseconds < 100) return;
    _lastProject = now;
    unawaited(_updateCarScreen());
  }

  /// Projects the car's geo position (and the trip stops) to their on-screen
  /// spots so the arrow + stop markers are always glued to the map (following
  /// or free). Clamped to the screen so nothing vanishes.
  Future<void> _updateCarScreen() async {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    try {
      final size = MediaQuery.of(context).size;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      // Car arrow.
      final p = await ctrl.toScreenLocation(
        LatLng(c.latitude, c.longitude),
      );
      if (!mounted) return;
      final off = Offset(
        ((p.x.toDouble() / dpr) - 37.5).clamp(0.0, size.width - 75.0),
        ((p.y.toDouble() / dpr) - 37.5).clamp(0.0, size.height - 75.0),
      );
      // Trip stop markers (numbered waypoints) — same physical→logical fix
      // as the car (toScreenLocation returns device pixels, /dpr = logical).
      final stops = widget.stops;
      final screens = <Offset?>[];
      for (final s in stops) {
        try {
          final sp = await ctrl.toScreenLocation(LatLng(s.lat, s.lng));
          screens.add(
            Offset(sp.x.toDouble() / dpr, sp.y.toDouble() / dpr),
          );
        } catch (_) {
          screens.add(null);
        }
      }
      if (!mounted) return;
      var changed = _carScreen != off;
      if (screens.length != _stopScreens.length) changed = true;
      if (!changed) {
        for (var i = 0; i < screens.length; i++) {
          if (screens[i] != _stopScreens[i]) {
            changed = true;
            break;
          }
        }
      }
      if (changed) {
        setState(() {
          _carScreen = off;
          _stopScreens
            ..clear()
            ..addAll(screens);
        });
      }
    } catch (_) {
      // Projection failed (e.g. car off-screen / map busy) — fall back to
      // center so the arrow never vanishes.
      if (mounted && _carScreen != null) setState(() => _carScreen = null);
    }
  }

  /// Apply a camera move we own (focus a POI) so [_onCamIdle] can tell it
  /// apart from a user gesture.
  void _followMove(MapLibreMapController ctrl, CameraPosition p) {
    _lastFollowCam = p;
    ctrl.moveCamera(CameraUpdate.newCameraPosition(p));
  }

  /// Camera target for [car]: the car itself when [_carAnchor] is 0 (centered)
  /// or shifted ahead of the travel direction by [_carAnchor]×visible so the
  /// car sits lower on screen (more road ahead, classic Google framing).
  ll.LatLng _followTarget(ll.LatLng car, double bearingDeg, double zoom) {
    // Approx ground meters per pixel at this zoom (Web Mercator).
    final mpp =
        156543.03392 *
        math.cos(car.latitude * math.pi / 180) /
        math.pow(2, zoom);
    // Visible vertical ground extent: viewport px × m/px × 3D-tilt extension
    // (tilted camera looks further ahead).
    final visible = 1100.0 * mpp * 1.8;
    final offset = _carAnchor * visible;
    if (offset <= 0) return car; // dead-center follow
    final rad = bearingDeg * math.pi / 180;
    final dLat = offset * math.cos(rad) / 111320.0;
    final dLng =
        offset *
        math.sin(rad) /
        (111320.0 * math.cos(car.latitude * math.pi / 180));
    return ll.LatLng(car.latitude + dLat, car.longitude + dLng);
  }

  /// Approximate ground distance in meters between two points.
  double _distMeters(ll.LatLng a, ll.LatLng b) {
    final dLat = (b.latitude - a.latitude) * 111320.0;
    final dLng =
        (b.longitude - a.longitude) *
        111320.0 *
        math.cos(a.latitude * math.pi / 180);
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  @override
  void didUpdateWidget(VectorNavMap old) {
    super.didUpdateWidget(old);
    if (old.headingUp != widget.headingUp || old.tilt3D != widget.tilt3D) {
      // Force a re-follow with the new north/heading-up bearing or tilt.
      _hasPosition = false;
      _lastFollowCam = null;
    }
    if (old.terrain3D != widget.terrain3D ||
        old.nightMode != widget.nightMode ||
        old.satellite != widget.satellite) {
      // Rebuild the style (terrain / night / satellite) and hot-swap it via
      // setStyle — much lighter than re-creating the whole platform view
      // (which reset the camera and flashed on low-end devices). Annotations
      // are dropped and re-added by the style-loaded callback.
      _styleString = _buildStyleString();
      final ctrl = _controller;
      if (ctrl != null) {
        unawaited(_reloadStyle(ctrl, _styleString!));
      } else if (mounted) {
        setState(() {});
      }
    }
    if (old.selectedPoi != widget.selectedPoi && widget.selectedPoi != null) {
      _focusPoi(widget.selectedPoi!);
    }
    _followPosition();
    _updateRoute();
    _updatePois();
  }

  /// Hot-swap the style at runtime (terrain / night toggles). Old annotation
  /// handles are invalidated by `setStyle`, so clear them — the plugin's
  /// style-loaded callback re-creates the route + puck + POIs.
  Future<void> _reloadStyle(MapLibreMapController ctrl, String style) async {
    _resetAnnotations();
    try {
      await ctrl.setStyle(style);
    } catch (e) {
      debugPrint('VECTORMAP: setStyle failed: $e');
    }
    if (mounted) _followPosition();
  }

  void _resetAnnotations() {
    _lastRouteSig = null;
    _lastPoiSig = null;
    _casing = null;
    _routeLine = null;
    _trafficLines.clear();
    _trafficLights.clear();
    _poiCircles.clear();
    _poiSymbols.clear();
  }

  /// Center the camera on the tapped POI and pause auto-follow so the user
  /// can inspect it; the recenter button / 10 s idle brings the camera back
  /// to the car.
  void _focusPoi(PoiResult p) {
    final ctrl = _controller;
    if (ctrl == null) return;
    _followEnabled = false;
    widget.controller?.setFollowing(false);
    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 10), _recenter);
    _followMove(
      ctrl,
      CameraPosition(
        target: LatLng(p.lat, p.lng),
        zoom: 17,
        bearing: 0,
        tilt: 0,
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_styleError != null) {
      return const ColoredBox(color: Color(0xFFE8EAED));
    }
    if (_mapMissing) {
      return ColoredBox(
        color: const Color(0xFFE8EAED),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.map_outlined, size: 52, color: Colors.grey),
                const SizedBox(height: 14),
                const Text(
                  'Bản đồ dẫn đường chưa được tải',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Vào ⚙ Cài đặt → Bản đồ ngoại tuyến → "Bản đồ dẫn đường"\n'
                  'để tải bản đồ vector dùng khi chỉ đường.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final style = _styleString;
    if (style == null) {
      // Preparing the offline map.
      return const ColoredBox(color: Color(0xFFE8EAED));
    }
    final c = widget.current;
    // No pointer wrapper around MapLibreMap — an ancestor Listener interferes
    // with the platform view's multitouch. Follow uses MapLibre's native
    // `animateCamera` (auto-cancelled on user touch) and user takeover is
    // detected in [_onCamIdle] (camera stops somewhere other than where the
    // follow put it) → pan / pinch / rotate all work and pause the follow.
    return Stack(
      children: [
        MapLibreMap(
          styleString: style,
          initialCameraPosition: CameraPosition(
            target: c == null
                ? const LatLng(10.8231, 106.6297)
                : LatLng(c.latitude, c.longitude),
            zoom: _zoom,
          ),
          minMaxZoomPreference: const MinMaxZoomPreference(
            3,
            19,
          ), // pinch up to z19 (overzoom)
          compassEnabled: true,
          // Required: onCameraIdle/onCameraMove (and `cameraPosition`) only
          // fire with this enabled.
          trackCameraPosition: true,
          onMapCreated: (ctrl) {
            debugPrint('VECTORMAP: map created');
            _controller = ctrl;
          },
          onCameraMove: _onCamMove,
          onCameraIdle: _onCamIdle,
          onStyleLoadedCallback: () async {
            debugPrint('VECTORMAP: style loaded — adding route');
            await _addRoute();
            _followPosition();
            await _updatePois();
          },
        ),
        // The car arrow: a Flutter overlay that needs NO per-frame MapLibre
        // symbol updates (which is what made the old platform puck blink on
        // the weak itel GPU). It is projected to the car's real on-screen
        // position on every camera move / GPS fix, so it advances smoothly
        // along the road and never vanishes (falls back to screen center if
        // the projection is momentarily unavailable). Rotation comes from
        // [_puckRotate] and refreshes on every parent rebuild (GPS fix).
        if (widget.current != null)
          if (_carScreen != null)
            Positioned(
              left: _carScreen!.dx,
              top: _carScreen!.dy,
              child: IgnorePointer(child: _carArrow()),
            )
          else
            Positioned.fill(
              child: IgnorePointer(child: Center(child: _carArrow())),
            ),
        // Trip stop indicators (numbered waypoints) — glued to the map.
        for (var i = 0;
            i < widget.stops.length && i < _stopScreens.length;
            i++)
          if (_stopScreens[i] != null)
            Positioned(
              left: _stopScreens[i]!.dx - 14,
              top: _stopScreens[i]!.dy - 26,
              child: IgnorePointer(
                child: _StopMarker(
                  index: i,
                  isDest: i == widget.stops.length - 1,
                ),
              ),
            ),
      ],
    );
  }

  /// The car puck: the Vietmap arrow / emoji image, rotated by [_puckRotate]
  /// (viewport-aligned; never the raw compass).
  Widget _carArrow() {
    return Transform.rotate(
      angle: _puckRotate() * math.pi / 180,
      child: Image.asset(
        'assets/offline_map/icons/${widget.carIcon}.png',
        width: 75,
        height: 75,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }

  /// The user dragged/zoomed the map away from the follow camera: keep it
  /// where they left it, show the recenter button and auto-center back after
  /// 10 s of no further interaction.
  void _userPanned() {
    if (!_followEnabled) return;
    _followEnabled = false;
    widget.controller?.setFollowing(false);
    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 10), _recenter);
    if (mounted) setState(() {});
    unawaited(_updateCarScreen());
  }

  /// Snap the camera back onto the car and resume auto-follow.
  void _recenter() {
    _recenterTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _followEnabled = true;
      _carScreen = null; // arrow back to screen center
    });
    widget.controller?.setFollowing(true);
    _hasPosition = false;
    _lastFollowCam = null;
    _followPosition();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recenterTimer?.cancel();
    _recenterTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }
}

/// Numbered waypoint marker for a trip stop (Google-style "1", "2", …). The
/// last stop (the destination) is drawn in red so it reads as the goal.
class _StopMarker extends StatelessWidget {
  const _StopMarker({required this.index, required this.isDest});

  /// 0-based stop index — rendered as index+1.
  final int index;
  final bool isDest;

  @override
  Widget build(BuildContext context) {
    final color = isDest ? const Color(0xFFC5221F) : const Color(0xFF1A73E8);
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4),
        ],
      ),
      child: Center(
        child: Text(
          '${index + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
