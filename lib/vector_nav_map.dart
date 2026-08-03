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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';

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
    this.current,
    this.heading,
    this.headingUp = true,
    this.carIcon = 'arrow',
  });

  /// Route polyline to draw (latlong2 points).
  final List<ll.LatLng> routeGeometry;

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
  Symbol? _carMarker;
  Circle? _carCone;
  bool _hasPosition = false;
  double _zoom = 17;
  ll.LatLng? _lastRouteSig;
  ll.LatLng? _lastCarPos;
  double? _lastIconRotate;
  String? _lastIconName;
  double? _lastBearing;

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
    _casing = await ctrl.addLine(LineOptions(
      geometry: pts,
      lineColor: '#ffffff',
      lineWidth: 9.0,
    ));
    _routeLine = await ctrl.addLine(LineOptions(
      geometry: pts,
      lineColor: '#4285F4',
      lineWidth: 6.0,
    ));
    _lastRouteSig = _routeSignature(widget.routeGeometry);
  }

  ll.LatLng? _routeSignature(List<ll.LatLng> pts) {
    if (pts.isEmpty) return null;
    return pts.first; // route changes are always a brand-new geometry
  }

  void _updateRoute() {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (_lastRouteSig != _routeSignature(widget.routeGeometry)) {
      final pts = widget.routeGeometry
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();
      if (pts.length >= 2) {
        ctrl.updateLine(_casing!,
            LineOptions(geometry: pts, lineColor: '#ffffff', lineWidth: 9.0));
        ctrl.updateLine(_routeLine!,
            LineOptions(geometry: pts, lineColor: '#4285F4', lineWidth: 6.0));
      }
      _lastRouteSig = _routeSignature(widget.routeGeometry);
    }
  }

  double _bearing() {
    if (widget.headingUp && (widget.heading ?? 0) > 0) return widget.heading!;
    return 0; // north-up
  }

  /// 3D perspective angle (Google-Maps-style) when navigating.
  static const double _tilt = 55;

  void _followPosition() {
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null) return;
    final bearing = _bearing();
    if (!_hasPosition) {
      ctrl.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(c.latitude, c.longitude),
        zoom: 17,
        bearing: bearing,
        tilt: _tilt,
      )));
      _hasPosition = true;
      _lastBearing = bearing;
    } else if (bearing != _lastBearing) {
      // Rotate the map to the new heading (heading-up mode), keep the 3D tilt.
      ctrl.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(c.latitude, c.longitude),
        zoom: _zoom,
        bearing: bearing,
        tilt: _tilt,
      )));
      _lastBearing = bearing;
    } else {
      // Just recentre on the exact position, keep zoom + bearing + tilt.
      ctrl.moveCamera(
          CameraUpdate.newLatLng(LatLng(c.latitude, c.longitude)));
    }
    _updateCarMarker();
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
    final ctrl = _controller;
    final c = widget.current;
    if (ctrl == null || c == null || _carMarker == null) return;
    final h = widget.heading ?? 0;
    final iconChanged = widget.carIcon != _lastIconName;
    final posChanged = _lastCarPos != c;
    final rotChanged = (h - (_lastIconRotate ?? 0)).abs() > 0.5;
    if (!posChanged && !rotChanged && !iconChanged) return;
    _lastCarPos = c;
    _lastIconRotate = h;
    _lastIconName = widget.carIcon;
    ctrl.updateSymbol(_carMarker!, SymbolOptions(
      geometry: LatLng(c.latitude, c.longitude),
      iconImage: widget.carIcon,
      iconSize: _iconSize(widget.carIcon),
      iconRotate: h,
      iconAnchor: 'center',
    ));
    ctrl.updateCircle(_carCone!, CircleOptions(
      geometry: LatLng(c.latitude, c.longitude),
    ));
  }

  @override
  void didUpdateWidget(VectorNavMap old) {
    super.didUpdateWidget(old);
    if (old.headingUp != widget.headingUp) {
      // Force a re-follow with the new north/heading-up bearing.
      _lastBearing = null;
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
          const MinMaxZoomPreference(3, 17), // cap at 17 (user's max)
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
    _controller?.dispose();
    super.dispose();
  }
}
