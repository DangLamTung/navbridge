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

class VectorNavMap extends StatefulWidget {
  const VectorNavMap({
    super.key,
    this.routeGeometry = const [],
    this.routeSteps = const [],
    this.current,
    this.heading,
    this.headingUp = true,
    this.carIcon = 'arrow',
  });

  /// Route polyline to draw (latlong2 points).
  final List<ll.LatLng> routeGeometry;

  /// Route steps (maneuvers) — used for the traffic-colored route and the
  /// intersection (traffic-light) dots.
  final List<OsrmStep> routeSteps;

  /// Live position to follow.
  final ll.LatLng? current;

  /// Heading (degrees, 0=N) from the phone's compass sensor.
  final double? heading;

  /// Rotate the map so the travel direction points up (Google-style).
  final bool headingUp;

  /// Car marker icon name (from [kCarIcons]).
  final String carIcon;

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
  Symbol? _carMarker;
  Circle? _carCone;
  bool _hasPosition = false;
  double _zoom = 18; // follow zoom (overzooms the z16 tiles, Google-style)
  ll.LatLng? _lastRouteSig;
  ll.LatLng? _lastCarPos;
  double? _lastIconRotate;
  String? _lastIconName;
  // Per-frame camera easing (Google feel): the camera AND the car icon glide
  // together toward the target so the icon stays locked to its screen anchor
  // instead of the camera lagging behind a jumping icon.
  ll.LatLng? _camPos; // current (eased) camera target
  double _camBearing = 0;
  ll.LatLng? _wantPos; // desired camera target (car + anchor offset)
  double _wantBearing = 0;
  Timer? _camTimer;

  /// scale per icon so each renders ~44px on screen.
  double _iconSize(String name) =>
      name == 'arrow' ? 0.24 : 0.16; // arrow=200px, emoji=300px

  @override
  void initState() {
    super.initState();
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
      final manifest = jsonDecode(await rootBundle
          .loadString('assets/offline_map/manifest.json')) as Map<String, dynamic>;

      final pmtilesFile = File('${dir.path}/${manifest['pmtiles']}');
      if (!pmtilesFile.existsSync()) {
        final data = await rootBundle
            .load('assets/offline_map/${manifest['pmtiles']}');
        await pmtilesFile
            .writeAsBytes(data.buffer.asUint8List(), flush: true);
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
      final styleRaw =
          await rootBundle.loadString('assets/offline_map/nav_style.json');
      final style = jsonDecode(styleRaw) as Map<String, dynamic>;
      final src = style['sources'] as Map<String, dynamic>;
      src['openmaptiles']['url'] =
          'pmtiles://file://${pmtilesFile.path}';
      style['glyphs'] =
          (style['glyphs'] as String).replaceAll('__NAV_FONTS__', fontsDir.path);
      style['sprite'] =
          (style['sprite'] as String).replaceAll('__NAV_SPRITE__', spriteDir.path);
      if (mounted) setState(() => _styleString = jsonEncode(style));
    } catch (e) {
      debugPrint('VECTORMAP: prepare failed: $e');
      if (mounted) setState(() => _styleError = '$e');
    }
  }

  Future<void> _loadIcons(MapLibreMapController ctrl) async {
    for (final name in kCarIcons) {
      try {
        final data = await rootBundle.load('assets/offline_map/icons/$name.png');
        await ctrl.addImage(name, data.buffer.asUint8List());
      } catch (e) {
        debugPrint('VECTORMAP: icon $name failed: $e');
      }
    }
  }

  Future<void> _addRoute() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final pts = widget.routeGeometry
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
    if (pts.length < 2) return;
    // White casing under the whole route (Google look).
    _casing = await ctrl.addLine(LineOptions(
      geometry: pts,
      lineColor: '#ffffff',
      lineWidth: 9.5,
    ));
    final steps = widget.routeSteps;
    if (steps.length >= 2) {
      // Google-Maps-style traffic overlay: split the route at each maneuver
      // and color every segment green/yellow/red by its implied speed.
      final segs = _splitAtSteps(pts, steps);
      for (var i = 0; i < segs.length; i++) {
        final lvl = _trafficLevel(steps[(i + 1).clamp(0, steps.length - 1)]);
        _trafficLines.add(await ctrl.addLine(LineOptions(
          geometry: segs[i],
          lineColor: _trafficColors[lvl],
          lineWidth: 6.5,
        )));
      }
      // Traffic-light dots at each intersection (skip start/end maneuvers).
      for (var i = 1; i < steps.length - 1; i++) {
        final m = steps[i].maneuver;
        final lvl = _trafficLevel(steps[i]);
        _trafficLights.add(await ctrl.addCircle(CircleOptions(
          geometry: LatLng(m.latitude, m.longitude),
          circleColor: _trafficColors[lvl],
          circleRadius: 5.0,
          circleStrokeColor: '#202124',
          circleStrokeWidth: 2.0,
          circleOpacity: 0.95,
        )));
      }
    } else {
      // No maneuver data → plain blue route line.
      _routeLine = await ctrl.addLine(LineOptions(
        geometry: pts,
        lineColor: '#4285F4',
        lineWidth: 6.0,
      ));
    }
    _lastRouteSig = _routeSignature(widget.routeGeometry);
  }

  /// Traffic level 0 (green) / 1 (yellow) / 2 (red). Uses the backend's live
  /// congestion level when available (Vietmap), else the step's implied speed
  /// as an offline stand-in.
  static int _trafficLevel(OsrmStep s) {
    if (s.congestion != null) return s.congestion!;
    if (s.type == 'arrive' || s.type == 'depart' || s.duration <= 0) {
      return 0;
    }
    final kmh = s.distance / s.duration * 3.6;
    if (kmh >= 35) return 0; // free flow
    if (kmh >= 20) return 1; // slow
    return 2; // congested
  }

  static const List<String> _trafficColors = [
    '#34A853', // green
    '#FBBC05', // yellow
    '#EA4335', // red
  ];

  /// Split the route polyline at each step-maneuver point so every segment
  /// can be colored independently.
  List<List<LatLng>> _splitAtSteps(List<LatLng> pts, List<OsrmStep> steps) {
    final cuts = <int>[0];
    for (var i = 1; i < steps.length - 1; i++) {
      final idx = _nearestIndex(pts, steps[i].maneuver);
      if (idx > cuts.last && idx < pts.length - 1) cuts.add(idx);
    }
    if (cuts.last < pts.length - 1) cuts.add(pts.length - 1);
    final out = <List<LatLng>>[];
    for (var i = 0; i < cuts.length - 1; i++) {
      out.add(pts.sublist(cuts[i], cuts[i + 1] + 1));
    }
    return out;
  }

  int _nearestIndex(List<LatLng> pts, ll.LatLng p) {
    var best = 0;
    var bd = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final d = _dist2(pts[i], p);
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  double _dist2(LatLng a, ll.LatLng b) {
    final dLat = a.latitude - b.latitude;
    final dLng = a.longitude - b.longitude;
    return dLat * dLat + dLng * dLng;
  }

  ll.LatLng? _routeSignature(List<ll.LatLng> pts) {
    if (pts.isEmpty) return null;
    return pts.first; // route changes are always a brand-new geometry
  }

  void _updateRoute() {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (_lastRouteSig != _routeSignature(widget.routeGeometry)) {
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
      _lastRouteSig = _routeSignature(widget.routeGeometry);
    }
  }

  double _bearing() {
    if (widget.headingUp && (widget.heading ?? 0) > 0) return widget.heading!;
    return 0; // north-up
  }

  /// 3D perspective angle (Google-Maps-style) when navigating.
  static const double _tilt = 55;

  /// Where the car sits on screen, as a fraction of the visible map height
  /// measured from the camera center. 0.0 = dead center. (A positive value
  /// would place the car lower on screen to show more road ahead; the user
  /// asked for the object to be centered, so this stays 0.)
  static const double _carAnchor = 0.0;

  void _followPosition() {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    final bearing = _bearing();
    final car = ll.LatLng(c.latitude, c.longitude);
    // Google-style framing: shift the camera ahead of the travel direction so
    // the car sits ~1/3 from the bottom and the road ahead is visible. The
    // user wants the car centered → [_carAnchor] = 0 keeps the camera on the
    // car itself.
    final ahead = _followTarget(car, bearing > 0 ? bearing : 0, _zoom);
    if (!_hasPosition) {
      _camPos = ahead;
      _camBearing = bearing;
      ctrl.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(ahead.latitude, ahead.longitude),
        zoom: _zoom,
        bearing: bearing,
        tilt: _tilt,
      )));
      _hasPosition = true;
    } else {
      final turned = ((bearing - _camBearing) % 360).abs() > 1.0;
      final moved = _camPos == null || _distMeters(_camPos!, ahead) > 2.0;
      if (turned || moved) {
        _wantPos = ahead;
        _wantBearing = bearing;
        _camTimer ??= Timer.periodic(
            const Duration(milliseconds: 33), _tickCamera);
      }
    }
    _updateCarMarker();
  }

  /// One easing step toward the desired camera target. The camera AND the car
  /// icon glide together, so the icon stays locked to its screen anchor
  /// (Google feel) instead of the camera lagging behind a jumping icon.
  void _tickCamera(Timer t) {
    if (!mounted) {
      _stopCameraEase();
      return;
    }
    final ctrl = _controller;
    final want = _wantPos;
    final cur = _camPos;
    if (ctrl == null || want == null || cur == null) {
      _stopCameraEase();
      return;
    }
    const k = 0.20; // per-tick ease factor (~30fps → converges in ~300ms)
    if (_distMeters(cur, want) < 0.5) {
      // Settled on the target.
      ctrl.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(want.latitude, want.longitude),
        zoom: _zoom,
        bearing: _wantBearing,
        tilt: _tilt,
      )));
      _camPos = want;
      _camBearing = _wantBearing;
      _stopCameraEase();
      return;
    }
    final lat = cur.latitude + (want.latitude - cur.latitude) * k;
    final lng = cur.longitude + (want.longitude - cur.longitude) * k;
    final bearing = _lerpBearing(_camBearing, _wantBearing, k);
    _camPos = ll.LatLng(lat, lng);
    _camBearing = bearing;
    ctrl.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
      target: LatLng(lat, lng),
      zoom: _zoom,
      bearing: bearing,
      tilt: _tilt,
    )));
    // Glide the icon with the camera: it sits offset BEHIND the camera
    // target, so place it at the eased position to keep it glued to the
    // anchor (no visible lag between camera and icon).
    final carPos = _followTarget(_camPos!, _wantBearing + 180, _zoom);
    _paintCar(carPos, bearing);
  }

  void _stopCameraEase() {
    _camTimer?.cancel();
    _camTimer = null;
  }

  /// Shortest-path bearing interpolation (350→10 goes through 0, not 340°).
  double _lerpBearing(double a, double b, double k) {
    var diff = (b - a) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return a + diff * k;
  }

  /// Camera target for [car]: the car itself when [_carAnchor] is 0 (centered)
  /// or shifted ahead of the travel direction by [_carAnchor]×visible so the
  /// car sits lower on screen (more road ahead, classic Google framing).
  ll.LatLng _followTarget(ll.LatLng car, double bearingDeg, double zoom) {
    // Approx ground meters per pixel at this zoom (Web Mercator).
    final mpp = 156543.03392 *
        math.cos(car.latitude * math.pi / 180) /
        math.pow(2, zoom);
    // Visible vertical ground extent: viewport px × m/px × 3D-tilt extension
    // (tilted camera looks further ahead).
    final visible = 1100.0 * mpp * 1.8;
    final offset = _carAnchor * visible;
    if (offset <= 0) return car; // dead-center follow
    final rad = bearingDeg * math.pi / 180;
    final dLat = offset * math.cos(rad) / 111320.0;
    final dLng = offset * math.sin(rad) /
        (111320.0 * math.cos(car.latitude * math.pi / 180));
    return ll.LatLng(car.latitude + dLat, car.longitude + dLng);
  }

  /// Approximate ground distance in meters between two points.
  double _distMeters(ll.LatLng a, ll.LatLng b) {
    final dLat = (b.latitude - a.latitude) * 111320.0;
    final dLng = (b.longitude - a.longitude) * 111320.0 *
        math.cos(a.latitude * math.pi / 180);
    return math.sqrt(dLat * dLat + dLng * dLng);
  }

  /// Soft halo under the car (Google-style location cone).
  Future<void> _ensureCarHalo() async {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null || _carCone != null) return;
    _carCone = await ctrl.addCircle(CircleOptions(
      geometry: LatLng(c.latitude, c.longitude),
      circleColor: '#4285F4',
      circleRadius: 18.0,
      circleOpacity: 0.28,
    ));
  }

  /// The car marker: a rotating symbol (arrow or fun emoji).
  Future<void> _ensureCarMarker() async {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    if (_carMarker == null) {
      await _loadIcons(ctrl);
      _carMarker = await ctrl.addSymbol(SymbolOptions(
        geometry: LatLng(c.latitude, c.longitude),
        iconImage: widget.carIcon,
        iconSize: _iconSize(widget.carIcon),
        iconRotate: widget.heading ?? 0,
        iconAnchor: 'center',
      ));
      _lastCarPos = c;
      _lastIconRotate = widget.heading ?? 0;
      _lastIconName = widget.carIcon;
    }
  }

  void _updateCarMarker() {
    final c = widget.current;
    if (c == null) return;
    _paintCar(ll.LatLng(c.latitude, c.longitude), widget.heading ?? 0);
  }

  /// Place the car icon + halo at [pos], rotated to [heading]. Called both on
  /// new GPS fixes and each camera-ease frame (to keep the icon glued to the
  /// screen anchor while the camera glides).
  void _paintCar(ll.LatLng pos, double heading) {
    final ctrl = _controller;
    if (ctrl == null || _carMarker == null) return;
    final iconChanged = widget.carIcon != _lastIconName;
    final posChanged =
        _lastCarPos == null || _distMeters(_lastCarPos!, pos) > 0.3;
    final rotChanged = (heading - (_lastIconRotate ?? 0)).abs() > 0.5;
    if (!posChanged && !rotChanged && !iconChanged) return;
    _lastCarPos = pos;
    _lastIconRotate = heading;
    _lastIconName = widget.carIcon;
    ctrl.updateSymbol(_carMarker!, SymbolOptions(
      geometry: LatLng(pos.latitude, pos.longitude),
      iconImage: widget.carIcon,
      iconSize: _iconSize(widget.carIcon),
      iconRotate: heading,
      iconAnchor: 'center',
    ));
    ctrl.updateCircle(_carCone!, CircleOptions(
      geometry: LatLng(pos.latitude, pos.longitude),
    ));
  }

  @override
  void didUpdateWidget(VectorNavMap old) {
    super.didUpdateWidget(old);
    if (old.headingUp != widget.headingUp) {
      // Force a re-follow with the new north/heading-up bearing.
      _camBearing = 0;
      _camPos = null;
      _wantPos = null;
    }
    _followPosition();
    _updateRoute();
  }

  @override
  Widget build(BuildContext context) {
    if (_styleError != null) {
      return const ColoredBox(color: Color(0xFFE8EAED));
    }
    final style = _styleString;
    if (style == null) {
      // Preparing the offline map.
      return const ColoredBox(color: Color(0xFFE8EAED));
    }
    final c = widget.current;
    return MapLibreMap(
      styleString: style,
      initialCameraPosition: CameraPosition(
        target: c == null
            ? const LatLng(10.8231, 106.6297)
            : LatLng(c.latitude, c.longitude),
        zoom: 15,
      ),
      minMaxZoomPreference:
          const MinMaxZoomPreference(3, 19), // pinch up to z19 (overzoom)
      compassEnabled: true,
      onMapCreated: (ctrl) => _controller = ctrl,
      onStyleLoadedCallback: () async {
        await _addRoute();
        await _ensureCarHalo();
        await _ensureCarMarker();
        _followPosition();
      },
    );
  }

  @override
  void dispose() {
    _camTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }
}
