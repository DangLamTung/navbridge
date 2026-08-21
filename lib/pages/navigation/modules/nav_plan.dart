part of '../navigation_page.dart';

/// PLANNING MODE — route-level tools shown while a route is planned but
/// navigation hasn't started (the RoutePreviewCard): export the planned
/// route to the common planning formats (GPX / KML / KMZ) and download the
/// offline map for the route's area.
extension _NavPlan on _NavigationPageState {
  /// Enter PLANNING MODE: directions UI with the end field focused so the
  /// user can pick start → destination → via points, preview the route and
  /// then export it (GPX/KML/KMZ) or download the offline map for the area.
  void _enterPlanningMode() {
    setNavState(() {
      _directionsMode = true;
      _navField = _NavField.end;
      _suggestions = [];
      _pickedPlace = null;
    });
    _searchFocus.requestFocus();
  }

  /// Readable route name, e.g. "Nhà riêng → Sân bay Tân Sơn Nhất".
  String get _planName {
    final dest = _destinationName;
    final o = _originName.trim();
    if (o.isEmpty) return dest;
    return '$o → $dest';
  }

  /// Ordered stop list for export: origin first (from the planned points),
  /// then the destination / via-points.
  List<TripStop> _exportStops() {
    final pts = _planPoints;
    final stops = List<TripStop>.from(_stops);
    if (pts.isNotEmpty) {
      stops.insert(
        0,
        TripStop(
          name: _originName.trim().isEmpty
              ? 'Điểm xuất phát'
              : _originName.trim(),
          lat: pts.first.latitude,
          lng: pts.first.longitude,
        ),
      );
    }
    return stops;
  }

  /// Share the planned route as a GPX 1.1 file (Garmin / OSMAnd / Komoot…).
  Future<void> _exportRouteGpx() async {
    final route = _route;
    if (route == null || route.geometry.isEmpty) return;
    final stops = _exportStops();
    final name = _planName;
    try {
      final base = sanitizeFileName(name).isEmpty
          ? 'tuyen'
          : sanitizeFileName(name);
      final f = await writeRouteExport(
        base,
        'gpx',
        utf8.encode(
          gpxFromRoute(name: name, geometry: route.geometry, stops: stops),
        ),
      );
      await Share.shareXFiles([
        XFile(f.path, mimeType: 'application/gpx+xml'),
      ], text: 'Tuyến đường — $name');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Không xuất được GPX: $e')));
      }
    }
  }

  /// Share the planned route as KML **and** KMZ (Google Earth / My Maps).
  Future<void> _exportRouteKmlKmz() async {
    final route = _route;
    if (route == null || route.geometry.isEmpty) return;
    final stops = _exportStops();
    final name = _planName;
    try {
      final base = sanitizeFileName(name).isEmpty
          ? 'tuyen'
          : sanitizeFileName(name);
      final kml = kmlFromRoute(
        name: name,
        geometry: route.geometry,
        stops: stops,
      );
      final kmlFile = await writeRouteExport(base, 'kml', utf8.encode(kml));
      final kmzFile = await writeRouteExport(
        base,
        'kmz',
        kmzFromKml(kml, base),
      );
      await Share.shareXFiles([
        XFile(kmlFile.path, mimeType: 'application/vnd.google-earth.kml+xml'),
        XFile(kmzFile.path, mimeType: 'application/vnd.google-earth.kmz'),
      ], text: 'Tuyến đường — $name');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('Không xuất được KML/KMZ: $e')),
          );
      }
    }
  }

  /// Download the offline (raster) map covering the planned route, into the
  /// ACTIVE basemap layer's folder so the browse map immediately serves it
  /// offline. The region is also saved to the shared offline-regions list
  /// (so it shows up in "Dữ liệu ngoại tuyến" and can be deleted there).
  Future<void> _downloadRouteMap() async {
    final route = _route;
    if (route == null || route.geometry.isEmpty) return;
    final b = _boundsForRoute(route.geometry);
    final region = OfflineRegion(
      name: 'Tuyến: $_planName',
      swLat: b.southWest.latitude,
      swLon: b.southWest.longitude,
      neLat: b.northEast.latitude,
      neLon: b.northEast.longitude,
      // Street-level detail without exploding the tile count for long trips.
      minZoom: 11,
      maxZoom: 15,
      downloadedAt: DateTime.now(),
    );
    final dl = RegionDownloader(region, source: _tileSource);
    if (dl.disabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chưa cấu hình nguồn tải bản đồ ngoại tuyến.'),
        ),
      );
      return;
    }
    final mb = region.estimatedBytes / (1024 * 1024);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tải bản đồ khu vực tuyến?'),
        content: Text(
          'Tuyến dài ${(route.distance / 1000).toStringAsFixed(1)} km — '
          'vùng bao quanh ~${region.tileCount} ô bản đồ (~${mb.toStringAsFixed(0)} MB, '
          'độ chi tiết 11–15). Dùng được khi mất sóng.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tải xuống'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RouteMapDownloadDialog(downloader: dl),
    );
    if (saved != true || !mounted) return;
    // Remember the region (even if a few tiles failed) so it's listed in
    // the offline screen and can be re-downloaded/deleted.
    final regions = await loadRegions();
    regions.add(region);
    await saveRegions(regions);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              dl.blocked
                  ? 'Nguồn bản đồ giới hạn tải (429/403). Thử lại sau.'
                  : 'Đã tải bản đồ vùng tuyến (${region.tileCount} ô).',
            ),
          ),
        );
    }
  }

  /// Padded bounding box of a polyline (enough margin to cover the road
  /// corridor around the route).
  LatLngBounds _boundsForRoute(List<LatLng> pts, {double padDeg = 0.02}) {
    var minLat = double.infinity, minLng = double.infinity;
    var maxLat = -double.infinity, maxLng = -double.infinity;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    if (minLat == double.infinity) {
      final c = _current ?? const LatLng(10.8231, 106.6297);
      return LatLngBounds(c, c);
    }
    return LatLngBounds(
      LatLng(minLat - padDeg, minLng - padDeg),
      LatLng(maxLat + padDeg, maxLng + padDeg),
    );
  }
}

/// Progress dialog for a route-area map download (cancel + blocked-429 alert).
class _RouteMapDownloadDialog extends StatefulWidget {
  const _RouteMapDownloadDialog({required this.downloader});
  final RegionDownloader downloader;

  @override
  State<_RouteMapDownloadDialog> createState() =>
      _RouteMapDownloadDialogState();
}

class _RouteMapDownloadDialogState extends State<_RouteMapDownloadDialog> {
  late final RegionDownloader _dl = widget.downloader;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _dl.download((done, total) {
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final total = _dl.total;
    final done = _dl.done;
    final pct = total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
    return AlertDialog(
      title: const Text('Đang tải bản đồ…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: pct),
          const SizedBox(height: 10),
          Text(
            _dl.blocked
                ? 'Bị giới hạn (429/403).'
                : _finished
                ? 'Xong: $done/$total ô'
                : '$done/$total ô',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        if (!_finished)
          TextButton(
            onPressed: () {
              _dl.cancel();
              Navigator.pop(context, false);
            },
            child: const Text('Huỷ'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xong'),
          ),
      ],
    );
  }
}
