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
    this.heading,
    this.headingUp = true,
    this.tilt3D = true,
    this.carIcon = 'arrow',
    this.pois = const [],
    this.selectedPoi,
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

  /// Heading (degrees, 0=N) from the phone's compass sensor.
  final double? heading;

  /// Rotate the map so the travel direction points up (Google-style).
  final bool headingUp;

  /// Tilted 3D perspective camera (Google-style). Turn off for a flat 2D map.
  final bool tilt3D;

  /// Car marker icon name (from [kCarIcons]).
  final String carIcon;

  /// Nearby POIs to highlight (gas/food/hotel/…) during navigation.
  final List<PoiResult> pois;

  /// The POI the user tapped — the camera centers on it (follow pauses).
  final PoiResult? selectedPoi;

  /// Camera-follow controller for the auto-center button (rendered by the
  /// page so it sits above the platform view).
  final VectorNavMapController? controller;

  @override
  State<VectorNavMap> createState() => _VectorNavMapState();
}

class _VectorNavMapState extends State<VectorNavMap> {
  MapLibreMapController? _controller;
  String? _styleString;
  String? _styleError;
  Line? _casing;
  Line? _routeLine;
  final List<Line> _trafficLines = [];
  final List<Circle> _trafficLights = [];
  final List<Circle> _poiCircles = [];
  final List<Symbol> _poiSymbols = [];
  String? _lastPoiSig;
  Symbol? _carMarker;
  bool _hasPosition = false;
  // Vietmap-style nav camera: start at max zoom with the car centered. The
  // user can pinch to a different zoom — it's adopted (see [_onCamMove]) so
  // follow keeps the map at the zoom the user chose instead of snapping back
  // to 19 (that's what made it feel "zoom in only").
  double _zoom = 19;
  String? _lastRouteSig;
  ll.LatLng? _lastCarPos;
  double? _lastIconRotate;
  String? _lastIconName;

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

  /// The camera we last requested for the follow ease — used in [_onCamMove]
  /// to tell our own moves from the user's pan/zoom (no pointer wrapper, so
  /// the platform view keeps full pan + pinch control).
  CameraPosition? _lastFollowCam;

  /// Icon scale. The navigation puck (arrow) is Vietmap's exact 75dp puck
  /// (white circle + #2a5dff arrow), rasterized at 4x (300px); MapLibre
  /// icon-size is in physical pixels, so scale by density to land at 75dp.
  double _iconSize(String name) {
    if (name == 'arrow') {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      return 75.0 * dpr / 300.0;
    }
    return 0.16; // emoji icons (300px) ~ 48px
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.attachRecenter(_recenter);
    widget.controller?.setFollowing(true);
    _prepare();
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
      style['glyphs'] = (style['glyphs'] as String).replaceAll(
        '__NAV_FONTS__',
        fontsDir.path,
      );
      style['sprite'] = (style['sprite'] as String).replaceAll(
        '__NAV_SPRITE__',
        spriteDir.path,
      );
      if (mounted) setState(() => _styleString = jsonEncode(style));
    } catch (e) {
      debugPrint('VECTORMAP: prepare failed: $e');
      if (mounted) setState(() => _styleError = '$e');
    }
  }

  Future<void> _loadIcons(MapLibreMapController ctrl) async {
    for (final name in kCarIcons) {
      try {
        final data = await rootBundle.load(
          'assets/offline_map/icons/$name.png',
        );
        await ctrl.addImage(name, data.buffer.asUint8List());
      } catch (e) {
        debugPrint('VECTORMAP: icon $name failed: $e');
      }
    }
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
    _casing = await ctrl.addLine(
      LineOptions(geometry: pts, lineColor: '#ffffff', lineWidth: 14),
    );
    _routeLine = await ctrl.addLine(
      LineOptions(geometry: pts, lineColor: '#1A73E8', lineWidth: 10),
    );
    _lastRouteSig = _routeSignature();
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
  /// Once a route bearing has been computed it is always reused — never the
  /// raw phone heading (which is noisy and made the arrow spin/flicker).
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

  /// Bearing of the route at the car: direction of the nearest polyline
  /// SEGMENT (perpendicular distance, not the nearest vertex — vertices flip
  /// between adjacent segments as the car moves, which made the bearing — and
  /// therefore the arrow — jump). The result is cached and reused when the
  /// route is briefly absent so the camera never falls back to the compass.
  double _routeBearing() {
    final c = widget.current;
    final g = widget.routeGeometry;
    if (c == null || g.length < 2) {
      return _hasRouteBearing ? _lastRouteBearing : (widget.heading ?? 0);
    }
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < g.length - 1; i++) {
      final d = _distToSegment(c, g[i], g[i + 1]);
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    final a = g[bi];
    final b = g[bi + 1];
    final y =
        math.sin((b.longitude - a.longitude) * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180);
    final x =
        math.cos(a.latitude * math.pi / 180) *
            math.sin(b.latitude * math.pi / 180) -
        math.sin(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.cos((b.longitude - a.longitude) * math.pi / 180);
    final bearing = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    _lastRouteBearing = bearing;
    _hasRouteBearing = true;
    return bearing;
  }

  /// Perpendicular distance (meters) from [p] to segment [a]-[b].
  double _distToSegment(ll.LatLng p, ll.LatLng a, ll.LatLng b) {
    // Equirectangular local meters about p (fine within a route window).
    const mPerLat = 111320.0;
    final mPerLng = 111320.0 * math.cos(p.latitude * math.pi / 180);
    final ax = (a.longitude - p.longitude) * mPerLng;
    final ay = (a.latitude - p.latitude) * mPerLat;
    final bx = (b.longitude - p.longitude) * mPerLng;
    final by = (b.latitude - p.latitude) * mPerLat;
    final abx = bx - ax;
    final aby = by - ay;
    final len2 = abx * abx + aby * aby;
    var t = len2 == 0 ? 0.0 : -(ax * abx + ay * aby) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * abx;
    final cy = ay + t * aby;
    return math.sqrt(cx * cx + cy * cy);
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
    // User is free on the map (follow paused): keep the puck glued to the
    // REAL fix so it stays at the car's position while they pan/zoom.
    if (!_followEnabled) {
      _updateCarMarker();
      return;
    }
    // Adopt the live camera zoom (whatever the user pinched to) so follow
    // never forces the zoom back to the initial max.
    final live = ctrl.cameraPosition;
    if (live != null && live.zoom >= 3) _zoom = live.zoom.clamp(3.0, 19.0);
    // While following, the puck is painted ONLY from onCameraMove/onCameraIdle
    // at the camera target — painting the raw fix here too made the puck jump
    // ahead of the glide and then snap back every tick (the flicker).
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

  /// Glue the car icon to the camera while the follow animation glides, so
  /// the arrow never detaches from the screen anchor / jumps / flickers
  /// (with a fixed 300 px puck at max zoom even a few meters of lag looks
  /// like the marker blinking out). `_paintCar`'s 0.3 m guard keeps this
  /// cheap — it only calls `updateSymbol` when the puck actually moves.
  ///
  /// MapLibre can occasionally report a `cam.target` that has drifted well
  /// off the road mid-animation (a tilted bearing-change pivot) — painting
  /// that would teleport the puck off-route for a frame (the flicker). Clamp:
  /// if the camera target is far from the snapped car, keep the puck on the
  /// car instead.
  void _onCamMove(CameraPosition cam) {
    if (!_followEnabled) return;
    final t = cam.target;
    final cur = widget.current;
    if (cur != null &&
        _distMeters(
              ll.LatLng(cur.latitude, cur.longitude),
              ll.LatLng(t.latitude, t.longitude),
            ) >
            50) {
      _paintCar(ll.LatLng(cur.latitude, cur.longitude));
    } else {
      _paintCar(ll.LatLng(t.latitude, t.longitude));
    }
  }

  /// Fires when the camera stops moving: either our follow animation finished
  /// (camera sits on [_lastFollowCam] → keep following) or the user
  /// interrupted it with a pan / pinch / rotate (camera deviated → pause
  /// follow, show the recenter button, auto-center after 10 s).
  void _onCamIdle() {
    final last = _lastFollowCam;
    final ctrl = _controller;
    if (last == null || ctrl == null || !_followEnabled || !_hasPosition) {
      return;
    }
    final cam = ctrl.cameraPosition;
    if (cam == null) return;
    final t = cam.target;
    // Final puck placement: glue the arrow onto the SETTLED CAMERA target so
    // it never detaches from the screen anchor. (Painting the LIVE snapped
    // fix here made the puck jump ~500 ms of travel ahead of the camera at
    // every settle and snap back each tick — the original flicker.) Only when
    // MapLibre settles on a target that has drifted far off the road (a
    // tilted bearing-change pivot) do we paint the real snapped position
    // instead, so the puck stays on the route.
    final cur = widget.current;
    if (cur != null &&
        _distMeters(
              ll.LatLng(cur.latitude, cur.longitude),
              ll.LatLng(t.latitude, t.longitude),
            ) >
            50) {
      _paintCar(ll.LatLng(cur.latitude, cur.longitude));
    } else {
      _paintCar(ll.LatLng(t.latitude, t.longitude));
    }
    final targetClose =
        _distMeters(
          ll.LatLng(last.target.latitude, last.target.longitude),
          ll.LatLng(t.latitude, t.longitude),
        ) <
        8;
    final zoomClose = (cam.zoom - last.zoom).abs() < 0.15;
    final b = (cam.bearing - last.bearing) % 360;
    final bearingClose = b.abs() < 5 || b.abs() > 355;
    if (!targetClose || !zoomClose || !bearingClose) {
      _userPanned(); // the user took over the map
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

  /// Soft halo under the car (Google-style location cone) — removed: the
  /// Vietmap navigation puck carries its own white halo.
  /// The car marker: the Vietmap navigation puck (white circle + blue arrow)
  /// or a fun emoji. Rotation is viewport-aligned (see [_puckRotate]).
  Future<void> _ensureCarMarker() async {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    if (_carMarker == null) {
      await _loadIcons(ctrl);
      try {
        _carMarker = await ctrl.addSymbol(
          SymbolOptions(
            geometry: LatLng(c.latitude, c.longitude),
            iconImage: widget.carIcon,
            iconSize: _iconSize(widget.carIcon),
            iconRotate: _puckRotate(),
            iconAnchor: 'center',
          ),
        );
        debugPrint('VECTORMAP: car marker created (${widget.carIcon})');
      } catch (e) {
        debugPrint('VECTORMAP: car marker failed: $e');
      }
      _lastCarPos = c;
      _lastIconRotate = _puckRotate();
      _lastIconName = widget.carIcon;
    }
  }

  void _updateCarMarker() {
    final c = widget.current;
    if (c == null) return;
    _paintCar(ll.LatLng(c.latitude, c.longitude));
  }

  /// Place the puck icon at [pos] (rotated by [_puckRotate]). Called both on
  /// new GPS fixes and each camera-ease frame (to keep the icon glued to the
  /// screen anchor while the camera glides).
  void _paintCar(ll.LatLng pos) {
    final ctrl = _controller;
    if (ctrl == null || _carMarker == null) return;
    final iconChanged = widget.carIcon != _lastIconName;
    final posChanged =
        _lastCarPos == null || _distMeters(_lastCarPos!, pos) > 0.3;
    final rotate = _puckRotate();
    final rotChanged = (rotate - (_lastIconRotate ?? 0)).abs() > 0.5;
    if (!posChanged && !rotChanged && !iconChanged) return;
    debugPrint(
      'VECTORMAP: paint car @'
      '${pos.latitude.toStringAsFixed(5)},${pos.longitude.toStringAsFixed(5)} '
      'rot=$rotate',
    );
    _lastCarPos = pos;
    _lastIconRotate = rotate;
    _lastIconName = widget.carIcon;
    ctrl.updateSymbol(
      _carMarker!,
      SymbolOptions(
        geometry: LatLng(pos.latitude, pos.longitude),
        iconImage: widget.carIcon,
        iconSize: _iconSize(widget.carIcon),
        iconRotate: _puckRotate(),
        iconAnchor: 'center',
      ),
    );
  }

  @override
  void didUpdateWidget(VectorNavMap old) {
    super.didUpdateWidget(old);
    if (old.headingUp != widget.headingUp || old.tilt3D != widget.tilt3D) {
      // Force a re-follow with the new north/heading-up bearing or tilt.
      _hasPosition = false;
      _lastFollowCam = null;
    }
    if (old.selectedPoi != widget.selectedPoi && widget.selectedPoi != null) {
      _focusPoi(widget.selectedPoi!);
    }
    _followPosition();
    _updateRoute();
    _updatePois();
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
    return MapLibreMap(
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
      // Required: onCameraMove/onCameraIdle (and `cameraPosition`) only fire
      // with this enabled.
      trackCameraPosition: true,
      onMapCreated: (ctrl) => _controller = ctrl,
      onCameraMove: _onCamMove,
      onCameraIdle: _onCamIdle,
      onStyleLoadedCallback: () async {
        await _addRoute();
        await _ensureCarMarker();
        _followPosition();
        await _updatePois();
      },
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
  }

  /// Snap the camera back onto the car and resume auto-follow.
  void _recenter() {
    _recenterTimer?.cancel();
    if (!mounted) return;
    setState(() => _followEnabled = true);
    widget.controller?.setFollowing(true);
    _hasPosition = false;
    _lastFollowCam = null;
    _followPosition();
  }

  @override
  void dispose() {
    _recenterTimer?.cancel();
    _recenterTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }
}
