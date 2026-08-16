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
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:navbridge/services/osrm.dart';
import 'package:navbridge/services/offline_cameras.dart';
import 'package:navbridge/services/poi_search.dart';
import 'package:navbridge/services/terrain.dart';
import 'package:navbridge/services/vietmap_config.dart' show VietmapConfig;
import 'package:navbridge/core/car_filter.dart';
import 'package:navbridge/core/trip_plan.dart';

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
    this.searchPois = const [],
    this.stops = const [],
    this.cameras = const [],
    this.satellite = false,
    this.vietmapBase = false,
    this.tileSource = 'osm',
    this.smoothCamera = true,
    this.controller,
    this.showCompass = true,
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

  /// Search-bar results during navigation — drawn as blue place markers so
  /// the driver sees the found options ahead on the map (not just the text
  /// list). Ranked by route position (ahead, same side of road).
  final List<PoiResult> searchPois;

  /// Multi-stop trip waypoints — drawn as numbered markers on the map so the
  /// driver sees where each stop is.
  final List<TripStop> stops;

  /// Speed / red-light / enforcement cameras to show on the map (colored
  /// dot + camera tag). Empty = no camera layer.
  final List<OfflineCamera> cameras;

  /// Satellite imagery basemap (ESRI World Imagery, free) — shows real
  /// terrain, nicer for mountain views than the light vector map. Online
  /// only; falls back to the vector/light map when offline.
  final bool satellite;

  /// Vietmap light-raster basemap in nav mode — used when the Vietmap data
  /// source is active and online. Only affects the online raster fallback
  /// (below the vector layers); offline the bundled vector map still draws
  /// through, and the caller gates this on [VietmapConfig.hasKeys] so the
  /// keyed URL is never used without a real key.
  final bool vietmapBase;

  /// Active basemap layer from the page (`osm` / `carto` / `topo` / `esri` /
  /// `vietmap`…). Used for the ONLINE raster fallback (below the vector
  /// tiles) so the nav map keeps the SAME look the user picked while
  /// browsing — an OSM user gets OSM fallback tiles, not a surprise CARTO.
  final String tileSource;

  /// Google-style smooth map movement: a ticker eases the camera toward the
  /// live (dead-reckoned) car position every frame instead of one ~500 ms
  /// jump per 1 Hz GPS fix (that jump + freeze is what made the map stutter).
  /// Off → the legacy per-fix jump.
  final bool smoothCamera;

  /// Camera-follow controller for the auto-center button (rendered by the
  /// page so it sits above the platform view).
  final VectorNavMapController? controller;

  /// Show the MapLibre compass button (default on). Off in the tiny PiP
  /// window where it just eats space — heading-up follow already keeps the
  /// map oriented.
  final bool showCompass;

  @override
  State<VectorNavMap> createState() => _VectorNavMapState();
}

class _VectorNavMapState extends State<VectorNavMap>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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
  final List<Circle> _searchCircles = [];
  final List<Symbol> _searchSymbols = [];
  String? _lastSearchSig;
  final List<Circle> _cameraCircles = [];
  String? _lastCameraSig;
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

  /// Smooth car-arrow rotation: the arrow currently drawn on screen (deg),
  /// eased toward [_puckTargetDeg] every tick. GPS fixes arrive ~1 Hz, so
  /// without this the Transform.rotate angle snaps between fixes (north-up
  /// mode). The ticker runs only while the target differs meaningfully and
  /// stops once converged. The camera stays on the engine bearing + native
  /// animateCamera; this only smooths the arrow itself.
  late final Ticker _puckTicker;
  double _puckAngleDeg = 0;
  double _puckTargetDeg = 0;
  bool _puckHasTarget = false;
  bool _puckAnimating = false;

  /// Google-style camera follow: a ticker eases the camera toward the live
  /// (dead-reckoned) car position every frame. Active only while auto-follow
  /// is on and GPS fixes are flowing.
  late final Ticker _camTicker;
  bool _camAnimating = false;

  /// Dead-reckoned car position — advanced between 1 Hz GPS fixes at the
  /// filtered speed along the filter heading, so the map keeps gliding
  /// instead of freezing between fixes.
  ll.LatLng? _drPos;
  double _drSpeedMps = 0; // CarFilter-smoothed speed estimate (m/s)
  DateTime _drLastFix = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCamStep = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCamMove = DateTime.fromMillisecondsSinceEpoch(0);

  /// Constant-velocity complementary filter: fuses the 1 Hz GPS fixes into a
  /// smooth position + speed + heading, and dead-reckons between them (this
  /// replaced the old finite-difference speed estimate, which GPS jitter made
  /// jumpy — the car used to lurch / the arrow used to shake). It assumes the
  /// car is always on the route, so it follows the engine's route bearing and
  /// keeps the puck glued to the snapped fix.
  final CarFilter _kf = CarFilter();

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
    _puckTicker = createTicker(_onPuckTick);
    _camTicker = createTicker(_onCamTick);
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
    // 2D mode (3D toggle off): drop the `building-3d` fill-extrusion layer so
    // the GPU never processes extruded geometry — a flat 2D footprint keeps
    // navigation light. 3D mode keeps it so buildings render with real height.
    if (!widget.tilt3D) {
      final layers = style['layers'] as List<dynamic>?;
      if (layers != null) {
        layers.removeWhere((l) => l is Map && l['id'] == 'building-3d');
      }
    }
    // Satellite basemap: swap the online raster-fallback to ESRI World
    // Imagery (free, no key — real terrain photos, great for mountains).
    // Offline it stays transparent and the vector map shows through.
    final src = style['sources'] as Map<String, dynamic>;
    final fallback = src['raster-fallback'] as Map<String, dynamic>?;
    if (fallback != null) {
      // Raster fallback URL + attribution, chosen to MATCH the active
      // basemap layer ([tileSource]) so the nav map doesn't suddenly look
      // like a different map type. Explicit overrides (satellite / night /
      // Vietmap source) take priority; otherwise follow the user's layer.
      String url;
      String attribution;
      if (widget.satellite) {
        url =
            'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/{z}/{y}/{x}';
        attribution = '© ESRI';
      } else if (widget.nightMode) {
        // No dark styles for OSM/topo — use CARTO dark (looks dark like the
        // rest of the night theme).
        url = 'https://basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png';
        attribution = '© CARTO © OpenStreetMap';
      } else if (widget.vietmapBase) {
        // Vietmap light raster when the Vietmap source is active (online).
        // The caller gates this on hasKeys, so apikey is always present.
        url = VietmapConfig.mapTiles;
        attribution = '© Vietmap';
      } else {
        // Match the user's chosen basemap layer.
        switch (widget.tileSource) {
          case 'topo':
            url = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';
            attribution = '© OpenTopoMap © OpenStreetMap';
          case 'esri':
            url =
                'https://server.arcgisonline.com/ArcGIS/rest/services/'
                'World_Imagery/MapServer/tile/{z}/{y}/{x}';
            attribution = '© ESRI';
          case 'vietmap':
            url = VietmapConfig.mapTiles;
            attribution = '© Vietmap';
          default: // 'osm' (and any unknown → OSM style)
            url = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
            attribution = '© OpenStreetMap';
        }
      }
      fallback['tiles'] = [url];
      fallback['attribution'] = attribution;
    }
    // Night mode: remap the whole vector style to a REAL dark palette (light
    // fills → dark, roads → medium gray, labels → light text on a dark halo)
    // instead of dimming the light map with a black overlay. The route and
    // car arrow are separate annotations, so they stay bright on top.
    if (widget.nightMode) {
      return _darkStyle(style);
    }
    return jsonEncode(style);
  }

  /// Real dark-map theme for the vector style (used when [widget.nightMode]).
  /// Every paint color is remapped to a dark version of the same hue — light
  /// fills become dark fills, roads become medium gray, labels become light
  /// text on a dark halo — so the map is genuinely dark, not just dimmed.
  String _darkStyle(Map<String, dynamic> style) {
    final s = jsonDecode(jsonEncode(style)) as Map<String, dynamic>;
    final layers = s['layers'] as List<dynamic>;
    for (final l in layers) {
      if (l is! Map) continue;
      final paint = l['paint'];
      if (paint is! Map) continue;
      l['paint'] = _darkPaint(paint.cast<String, dynamic>());
    }
    return jsonEncode(s);
  }

  Map<String, dynamic> _darkPaint(Map<String, dynamic> paint) {
    final out = <String, dynamic>{};
    paint.forEach((key, value) {
      final k = key.toLowerCase();
      out[key] = _darkColorValue(
        value,
        isText: k.contains('text-color') || k.contains('icon-color'),
        isHalo: k.contains('halo-color'),
        isFill: k.contains('fill-color') || k.contains('fill-extrusion'),
        isLine: k.contains('line-color'),
        isBg: k.contains('background-color'),
      );
    });
    return out;
  }

  dynamic _darkColorValue(
    Object? v, {
    required bool isText,
    required bool isHalo,
    required bool isFill,
    required bool isLine,
    required bool isBg,
  }) {
    if (v is String) {
      return _darkColor(
        v,
        isText: isText,
        isHalo: isHalo,
        isFill: isFill,
        isLine: isLine,
        isBg: isBg,
      );
    }
    if (v is Map) {
      final out = <String, dynamic>{};
      v.forEach((key, val) {
        if (key == 'stops' && val is List) {
          out[key] = val.map((e) {
            if (e is List && e.length == 2) {
              return [
                e[0],
                _darkColorValue(
                  e[1],
                  isText: isText,
                  isHalo: isHalo,
                  isFill: isFill,
                  isLine: isLine,
                  isBg: isBg,
                ),
              ];
            }
            return e;
          }).toList();
        } else {
          out[key] = val;
        }
      });
      return out;
    }
    return v;
  }

  /// Remap a single CSS color string to its dark-theme equivalent.
  String _darkColor(
    String css, {
    required bool isText,
    required bool isHalo,
    required bool isFill,
    required bool isLine,
    required bool isBg,
  }) {
    final hsl = _colorHsl(css);
    if (hsl == null) return css;
    final h = hsl[0];
    final s = hsl[1];
    final l = hsl[2];
    double nl;
    if (isHalo) {
      nl = 0.06; // dark halo so light labels read on the dark map
    } else if (isText) {
      nl = l < 0.5 ? 0.88 : l; // dark text → light
    } else if (isBg) {
      nl = (l * 0.15).clamp(0.10, 0.20).toDouble();
    } else if (isFill) {
      nl = (l * 0.22).clamp(0.10, 0.26).toDouble();
    } else if (isLine) {
      nl = (l * 0.45).clamp(0.28, 0.55).toDouble();
    } else {
      nl = (l * 0.30).clamp(0.12, 0.40).toDouble();
    }
    return _hslToHex(h, s, nl);
  }

  /// Parse a CSS hex / rgb(a) / hsl(a) color into [hue, sat, light] (0..1).
  List<double>? _colorHsl(String css) {
    final c = css.trim().toLowerCase();
    final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(c);
    if (hex != null) {
      var h = hex.group(1)!;
      if (h.length == 3) {
        h = h.split('').map((x) => '$x$x').join();
      }
      final r = int.parse(h.substring(0, 2), radix: 16) / 255;
      final g = int.parse(h.substring(2, 4), radix: 16) / 255;
      final b = int.parse(h.substring(4, 6), radix: 16) / 255;
      return _rgbToHsl(r, g, b);
    }
    final hsl = RegExp(
      r'^hsla?\(([\d.]+)[,\s]+([\d.]+)%[,\s]+([\d.]+)%',
    ).firstMatch(c);
    if (hsl != null) {
      return [
        double.parse(hsl.group(1)!) / 360.0,
        double.parse(hsl.group(2)!) / 100.0,
        double.parse(hsl.group(3)!) / 100.0,
      ];
    }
    final rgb = RegExp(
      r'^rgba?\(([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)',
    ).firstMatch(c);
    if (rgb != null) {
      return _rgbToHsl(
        double.parse(rgb.group(1)!) / 255,
        double.parse(rgb.group(2)!) / 255,
        double.parse(rgb.group(3)!) / 255,
      );
    }
    return null;
  }

  List<double> _rgbToHsl(double r, double g, double b) {
    final max = [r, g, b].reduce((a, x) => a > x ? a : x);
    final min = [r, g, b].reduce((a, x) => a < x ? a : x);
    final l = (max + min) / 2;
    if (max == min) return [0, 0, l];
    final d = max - min;
    final s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    double h;
    if (max == r) {
      h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
    } else if (max == g) {
      h = ((b - r) / d + 2) / 6;
    } else {
      h = ((r - g) / d + 4) / 6;
    }
    return [h, s, l];
  }

  String _hslToHex(double h, double s, double l) {
    double hue2rgb(double p, double q, double t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    final r = hue2rgb(p, q, h + 1 / 3);
    final g = hue2rgb(p, q, h);
    final b = hue2rgb(p, q, h - 1 / 3);
    String to2(double x) => (x * 255)
        .round()
        .clamp(0, 255)
        .toInt()
        .toRadixString(16)
        .padLeft(2, '0');
    return '#${to2(r)}${to2(g)}${to2(b)}';
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
        PoiType.cafeVong => '#B5651D',
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

  /// Search-bar place markers (blue dots + name) during navigation. Rebuilt
  /// when the ranked search result list changes. Mirrors [_updatePois].
  String _searchSignature(List<PoiResult> pois) =>
      pois.map((p) => '${p.lat},${p.lng}:${p.name}').join('|');

  Future<void> _updateSearchPois() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final sig = _searchSignature(widget.searchPois);
    if (sig == _lastSearchSig) return;
    _lastSearchSig = sig;
    for (final c in _searchCircles) {
      try {
        ctrl.removeCircle(c);
      } catch (_) {}
    }
    for (final s in _searchSymbols) {
      try {
        ctrl.removeSymbol(s);
      } catch (_) {}
    }
    _searchCircles.clear();
    _searchSymbols.clear();
    for (final p in widget.searchPois) {
      try {
        final c = await ctrl.addCircle(
          CircleOptions(
            geometry: LatLng(p.lat, p.lng),
            circleColor: '#1A73E8',
            circleRadius: 10.0,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2.5,
            circleOpacity: 0.95,
          ),
        );
        _searchCircles.add(c);
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
        _searchSymbols.add(s);
      } catch (_) {}
    }
  }

  /// Stable signature of the camera list (focus + position), so the layer is
  /// rebuilt only when the set actually changes — not on every GPS fix.
  String _cameraSignature(List<OfflineCamera> cams) => cams
      .map(
        (c) =>
            '${c.focus}:${c.lat.toStringAsFixed(5)},'
            '${c.lng.toStringAsFixed(5)}',
      )
      .join('|');

  /// Camera markers (colored dot per focus) on the nav map. Mirrors
  /// [_updatePois]: clear-then-rebuild when the signature changes.
  ///
  /// No text label: the offline font stack is Roboto (no emoji glyphs) and
  /// a label on every camera would clutter dense cities (HCMC has ~700). The
  /// circle color carries the type — red speed / amber red-light / blue
  /// general — matching the browse-map markers.
  Future<void> _updateCameras() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final cams = widget.cameras;
    final sig = _cameraSignature(cams);
    if (sig == _lastCameraSig) return;
    _lastCameraSig = sig;
    for (final c in _cameraCircles) {
      try {
        ctrl.removeCircle(c);
      } catch (_) {}
    }
    _cameraCircles.clear();
    for (final c in cams) {
      final col = switch (c.focus) {
        'speed' => '#D93025', // red — speed camera
        'red_light' => '#F9AB00', // amber — red-light camera
        _ => '#4285F4', // blue — general enforcement
      };
      try {
        // A dark halo + bright dot + white ring so the marker pops on the
        // dark nav map (the old single 6 px dot was easy to miss while
        // driving). The halo is drawn first so it sits behind the dot.
        final halo = await ctrl.addCircle(
          CircleOptions(
            geometry: LatLng(c.lat, c.lng),
            circleColor: col,
            circleRadius: 10.0,
            circleStrokeColor: '#202124',
            circleStrokeWidth: 3.0,
            circleOpacity: 0.35,
          ),
        );
        final circ = await ctrl.addCircle(
          CircleOptions(
            geometry: LatLng(c.lat, c.lng),
            circleColor: col,
            circleRadius: 7.0,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2.5,
            circleOpacity: 1.0,
          ),
        );
        _cameraCircles.add(halo);
        _cameraCircles.add(circ);
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

  /// Ease the drawn arrow angle toward [_puckTargetDeg] each tick (shortest
  /// path around the 0/360 wrap), stopping once converged. ~0.15/tick at
  /// 60 fps converges in a few frames, so the arrow reads as a smooth glide.
  void _onPuckTick(Duration elapsed) {
    if (!mounted) return;
    var d = (_puckTargetDeg - _puckAngleDeg + 540) % 360 - 180;
    _puckAngleDeg = (_puckAngleDeg + d * 0.15 + 360) % 360;
    if (d.abs() < 0.2) {
      _puckAngleDeg = _puckTargetDeg;
      _puckTicker.stop();
      _puckAnimating = false;
    } else {
      setState(() {});
    }
  }

  /// Point the arrow at [targetDeg], snapping on the very first target and
  /// easing thereafter. Starts the ticker only when the target differs from
  /// the current drawn angle by more than 0.3°.
  void _setPuckTarget(double targetDeg) {
    if (!_puckHasTarget) {
      _puckAngleDeg = targetDeg;
      _puckTargetDeg = targetDeg;
      _puckHasTarget = true;
      return;
    }
    final d = (targetDeg - _puckAngleDeg + 540) % 360 - 180;
    _puckTargetDeg = targetDeg;
    if (d.abs() > 0.3 && !_puckAnimating && mounted) {
      _puckAnimating = true;
      _puckTicker.start();
    }
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
    // Google-style smooth follow: a ticker eases the camera toward the live
    // (dead-reckoned) car position every frame. One camera move per 1 Hz GPS
    // fix (with the old 500 ms animation + freeze) is what made the map
    // stutter. When smoothing is off, do the single per-fix jump instead.
    if (widget.smoothCamera) {
      if (!_camAnimating && mounted) {
        _camAnimating = true;
        _lastCamStep = DateTime.now();
        _lastCamMove = DateTime.now();
        _camTicker.start();
      }
      return; // the ticker drives the camera each frame
    }
    _applyFollowCamera(ctrl, c);
  }

  /// Ease the camera toward [car] (the live or dead-reckoned position).
  void _applyFollowCamera(MapLibreMapController ctrl, ll.LatLng car) {
    // Adopt the live camera zoom (whatever the user pinched to) so follow
    // never forces the zoom back to the initial max.
    final live = ctrl.cameraPosition;
    if (live != null && live.zoom >= 3) _zoom = live.zoom.clamp(3.0, 19.0);
    if (ctrl.isCameraMoving) return;
    final bearing = _bearing();
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
    final tiltChanged = last == null || (want.tilt - last.tilt).abs() > 0.5;
    if (moved || turned || zoomChanged || tiltChanged) {
      _lastFollowCam = want;
      _hasPosition = true;
      if (widget.smoothCamera) {
        // Instant per-step move — the ~30 fps ticker cadence provides the
        // glide. (animateCamera would cancel the next tick's move.)
        _lastCamMove = DateTime.now();
        ctrl.moveCamera(CameraUpdate.newCameraPosition(want));
      } else {
        // Legacy per-fix jump (native animation, auto-cancelled on touch).
        unawaited(
          ctrl.animateCamera(
            CameraUpdate.newCameraPosition(want),
            duration: const Duration(milliseconds: 500),
          ),
        );
      }
    }
  }

  /// One camera-follow frame: advance the dead-reckoned car position along
  /// the last heading at the estimated speed, then step the camera toward it
  /// (~30 fps). Stops ~4 s after the last GPS fix (parked / GPS lost) so the
  /// map freezes instead of drifting forever.
  void _onCamTick(Duration elapsed) {
    if (!mounted) return;
    final ctrl = _controller;
    if (ctrl == null || !_followEnabled) {
      _camTicker.stop();
      _camAnimating = false;
      return;
    }
    final now = DateTime.now();
    final dr = _drPos;
    if (dr == null || now.difference(_drLastFix) > const Duration(seconds: 4)) {
      _camTicker.stop();
      _camAnimating = false;
      return;
    }
    final dtS = now.difference(_lastCamStep).inMilliseconds / 1000.0;
    _lastCamStep = now;
    // Dead-reckon: glide the car between 1 Hz GPS fixes using the Kalman
    // filter's predicted position (position + velocity fused from the fixes).
    if (dtS > 0 && dtS < 1.0 && _drSpeedMps > 0.5) {
      _drPos = _kf.predict(dtS);
    }
    // Parked + settled → stop ticking until the next GPS fix (saves battery).
    if (_drSpeedMps < 1.0 &&
        now.difference(_lastCamMove) > const Duration(milliseconds: 500)) {
      _camTicker.stop();
      _camAnimating = false;
      return;
    }
    // ~30 fps camera steps (moveCamera is instant; the ticker cadence gives
    // the Google-style glide instead of a 500 ms jump + freeze per fix).
    if (now.difference(_lastCamMove) >= const Duration(milliseconds: 33)) {
      _lastCamMove = now;
      _applyFollowCamera(ctrl, _drPos!);
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
      final p = await ctrl.toScreenLocation(LatLng(c.latitude, c.longitude));
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
          screens.add(Offset(sp.x.toDouble() / dpr, sp.y.toDouble() / dpr));
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

  /// Set the camera tilt to the current 3D setting (0 = flat 2D, [_tilt] =
  /// "3D nghiêng"), keeping target/zoom/bearing. No-op when it's already set.
  /// Called on the 3D toggle AND after a style reload so the camera angle
  /// visibly changes even when the car is parked (the follow ticker idles
  /// then and wouldn't otherwise re-apply it).
  void _applyCameraTilt() {
    final ctrl = _controller;
    final cam = ctrl?.cameraPosition;
    if (ctrl == null || cam == null) return;
    final want = widget.tilt3D ? _tilt : 0.0;
    if ((cam.tilt - want).abs() < 0.5) return;
    _lastFollowCam = null; // let the follow re-target with the new angle
    ctrl.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(cam.target.latitude, cam.target.longitude),
          zoom: cam.zoom,
          bearing: cam.bearing,
          tilt: want,
        ),
      ),
    );
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
    // Re-target the car-arrow rotation on every parent rebuild (GPS fix) so
    // the arrow glides instead of snapping between fixes.
    _setPuckTarget(_puckRotate());
    if (old.headingUp != widget.headingUp || old.tilt3D != widget.tilt3D) {
      // Force a re-follow with the new north/heading-up bearing or tilt.
      _hasPosition = false;
      _lastFollowCam = null;
      // Apply the new tilt immediately so the "3D (nghiêng)" toggle visibly
      // changes the camera angle.
      _applyCameraTilt();
    }
    if (old.terrain3D != widget.terrain3D ||
        old.tilt3D != widget.tilt3D ||
        old.nightMode != widget.nightMode ||
        old.satellite != widget.satellite ||
        old.vietmapBase != widget.vietmapBase ||
        old.tileSource != widget.tileSource) {
      // Rebuild the style (3D buildings / terrain / night / satellite /
      // basemap layer) and hot-swap it via setStyle — much lighter than
      // re-creating the whole platform view (which reset the camera and
      // flashed on low-end devices). Annotations are dropped and re-added
      // by the style-loaded callback.
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
    // Feed every NEW GPS fix into the Kalman filter (the map glides toward
    // its predicted position between fixes). latlong2's LatLng implements ==,
    // so `!=` detects a real position change — not a cosmetic rebuild.
    final newCur = widget.current;
    if (newCur != null && newCur != old.current) {
      final now = DateTime.now();
      // The engine's smoothed route-ahead bearing drives the dead-reckon
      // direction (the car is assumed to be on the route).
      _kf.update(newCur, routeBearing: _routeBearing());
      _drPos = _kf.position;
      _drSpeedMps = _kf.speedMps;
      _drLastFix = now;
    }
    _followPosition();
    _updateRoute();
    _updatePois();
    _updateSearchPois();
    _updateCameras();
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
    _lastSearchSig = null;
    _lastCameraSig = null;
    _casing = null;
    _routeLine = null;
    _trafficLines.clear();
    _trafficLights.clear();
    _poiCircles.clear();
    _poiSymbols.clear();
    _searchCircles.clear();
    _searchSymbols.clear();
    _cameraCircles.clear();
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
          compassEnabled: widget.showCompass,
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
            // The style reload reset the camera — re-apply the 3D tilt so
            // the toggle's effect survives (and works while parked).
            _applyCameraTilt();
            await _updatePois();
            await _updateSearchPois();
            await _updateCameras();
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
        for (var i = 0; i < widget.stops.length && i < _stopScreens.length; i++)
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
      angle: _puckAngleDeg * math.pi / 180,
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
    _puckTicker.dispose();
    _camTicker.dispose();
    // Do NOT dispose _controller here — the MapLibreMap widget owns the
    // controller it hands us via onMapCreated and disposes it itself. Calling
    // dispose() again throws "A MapLibreMapController was used after being
    // disposed" when exiting navigation.
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
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
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
