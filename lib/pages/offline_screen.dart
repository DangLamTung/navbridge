/// Offline map management: pick a region (preset / current view / current
/// location), see the estimated size, download with progress, and delete
/// downloaded regions.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/offline_router.dart';
import 'package:navbridge/services/offline_tiles.dart';
import 'package:navbridge/services/nav_map_store.dart';
import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/terrain.dart';
import 'package:navbridge/ui/widgets.dart';
import 'package:navbridge/services/vietmap_config.dart'
    show dataSource, graphDownloadBaseUrl;

String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  List<OfflineRegion> _regions = [];
  LatLngBounds _bounds = LatLngBounds(
    const LatLng(10.70, 106.60),
    const LatLng(10.85, 106.80),
  ); // HCMC core
  int _maxZoom = 16;
  int _minZoom = 1;
  bool _online = true;
  bool _forceOffline = false;
  bool _downloading = false;
  RegionDownloader? _dl;
  int _done = 0;
  int _total = 1;

  // --- offline vector nav map (PMTiles, downloadable) ---
  int _navBytes = 0;
  bool _navDownloaded = false;
  bool _navDownloading = false;
  int _navDone = 0;
  int _navTotal = 1;

  // --- offline 3D terrain (DEM, downloadable) ---
  int _terrainBytes = 0;
  bool _terrainDownloading = false;
  int _terrainDone = 0;
  int _terrainTotal = 1;

  // --- on-device routing graph (GraphHopper) ---
  bool _graphHas = false;
  bool _graphLoaded = false;
  bool _graphLoading = false;
  bool _graphDownloading = false;
  int _graphDone = 0;
  int _graphTotal = 1;
  int _graphBytes = 0;
  int _cacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    _refreshGraph();
    _refreshNavMap();
    _refreshTerrain();
    onlineStream().listen((o) => setState(() => _online = o));
    isOnline().then((o) => setState(() => _online = o));
    setState(() {
      _forceOffline = forceOffline;
    });
  }

  /// Snapshot the current globals into a persisted [AppSettings] — keeps ALL
  /// preference fields so editing one never drops the others.
  AppSettings _currentSettings() => AppSettings(
    forceOffline: forceOffline,
    dataSource: dataSource,
    vehicleType: vehicleType,
    geocodingProvider: geocodingProvider,
    routingEngine: routingEngine,
    smoothCamera: smoothCamera,
    cameraAlerts: cameraAlerts,
    radar: radarOn,
    pipAspect: pipAspect,
    ridingMode: ridingMode,
    simpleMode: simpleMode,
  );

  Future<void> _toggleForceOffline(bool v) async {
    setState(() => _forceOffline = v);
    forceOffline = v;
    await saveSettings(_currentSettings());
    // Tile cache is source-agnostic but network fetches stop/start here.
    setState(() {});
  }

  Future<void> _refreshGraph() async {
    final has = await routingGraphPresent();
    var bytes = 0;
    if (has) {
      final d = Directory(await routingGraphDir());
      await for (final f in d.list(recursive: true)) {
        if (f is File) bytes += f.lengthSync();
      }
    }
    await OfflineRouter.instance.refreshLoaded();
    if (mounted) {
      setState(() {
        _graphHas = has;
        _graphBytes = bytes;
        _graphLoaded = OfflineRouter.instance.isLoaded;
      });
    }
  }

  Future<void> _loadGraph() async {
    if (!await routingGraphPresent()) return;
    setState(() => _graphLoading = true);
    final ok = await OfflineRouter.instance.load(await routingGraphPath());
    if (mounted) {
      setState(() {
        _graphLoading = false;
        _graphLoaded = ok;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Đã nạp bộ dữ liệu chỉ đường.' : 'Không nạp được bộ dữ liệu.',
          ),
        ),
      );
    }
  }

  /// Download the GraphHopper graph (`.ghz`) from the configured GRAPH_URL,
  /// then load it. Mirrors the nav-map download (progress + snackbar).
  Future<void> _downloadGraph() async {
    if (_graphDownloading) return;
    setState(() {
      _graphDownloading = true;
      _graphDone = 0;
      _graphTotal = 1;
    });
    try {
      final ok = await downloadGraph((done, total) {
        if (mounted) {
          setState(() {
            _graphDone = done;
            _graphTotal = total;
          });
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Đã tải + nạp bộ dữ liệu chỉ đường.'
                  : 'Không nạp được bộ dữ liệu sau khi tải.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Tải bộ dữ liệu thất bại: $e')));
      }
    } finally {
      if (mounted) setState(() => _graphDownloading = false);
      await _refreshGraph();
    }
  }

  Future<void> _reload() async {
    final r = await loadRegions();
    final bytes = await tileCacheBytes();
    if (mounted) {
      setState(() {
        _regions = r;
        _cacheBytes = bytes;
      });
    }
  }

  Future<void> _clearCache() async {
    await clearTileCache();
    if (mounted) {
      setState(() => _cacheBytes = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xoá bộ nhớ đệm bản đồ.')),
      );
    }
  }

  Future<void> _refreshNavMap() async {
    final bytes = await navMapBytes();
    final downloaded = await navMapDownloaded();
    if (mounted) {
      setState(() {
        _navBytes = bytes;
        _navDownloaded = downloaded;
      });
    }
  }

  Future<void> _downloadNavMap() async {
    if (_navDownloading) return;
    setState(() {
      _navDownloading = true;
      _navDone = 0;
      _navTotal = 1;
    });
    try {
      await downloadNavMap((done, total) {
        if (mounted) {
          setState(() {
            _navDone = done;
            _navTotal = total;
          });
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã tải xong bản đồ dẫn đường.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Tải bản đồ thất bại: $e')));
      }
    } finally {
      if (mounted) setState(() => _navDownloading = false);
      await _refreshNavMap();
    }
  }

  Future<void> _deleteNavMap() async {
    await deleteNavMap();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xoá bản đồ dẫn đường đã tải.')),
      );
    }
    await _refreshNavMap();
  }

  // --- offline 3D terrain (DEM) -------------------------------------

  Future<void> _refreshTerrain() async {
    var bytes = 0;
    try {
      final root = await terrainTilesRoot();
      final dir = Directory(root);
      if (dir.existsSync()) {
        for (final f in dir.listSync(recursive: true)) {
          if (f is File && f.path.endsWith('.png')) bytes += f.lengthSync();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _terrainBytes = bytes);
  }

  Future<void> _downloadTerrain() async {
    if (_terrainDownloading) return;
    setState(() {
      _terrainDownloading = true;
      _terrainDone = 0;
      _terrainTotal = 1;
    });
    final dl = TerrainDownloader(_bounds);
    _terrainTotal = dl.total;
    try {
      await dl.download((done, total) {
        if (mounted) {
          setState(() {
            _terrainDone = done;
            _terrainTotal = total;
          });
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              dl.blocked
                  ? 'Máy chủ địa hình giới hạn tải (429/403). Thử lại sau.'
                  : 'Đã tải xong địa hình 3D.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Tải địa hình thất bại: $e')));
      }
    } finally {
      if (mounted) setState(() => _terrainDownloading = false);
      await _refreshTerrain();
    }
  }

  Future<void> _deleteTerrain() async {
    final root = await terrainTilesRoot();
    final dir = Directory(root);
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xoá địa hình 3D đã tải.')),
      );
    }
    await _refreshTerrain();
  }

  void _preset(LatLngBounds b) => setState(() => _bounds = b);

  Future<void> _pickCurrentLocation() async {
    LatLng? pos;
    try {
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
      pos = LatLng(p.latitude, p.longitude);
    } catch (_) {
      try {
        final p = await Geolocator.getLastKnownPosition();
        if (p != null) pos = LatLng(p.latitude, p.longitude);
      } catch (_) {}
    }
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không lấy được vị trí hiện tại.')),
        );
      }
      return;
    }
    const km = 0.009; // ~1 km per degree
    _preset(
      LatLngBounds(
        LatLng(pos.latitude - 5 * km, pos.longitude - 5 * km),
        LatLng(pos.latitude + 5 * km, pos.longitude + 5 * km),
      ),
    );
  }

  Future<void> _pickOnMap() async {
    final b = await Navigator.of(context).push<LatLngBounds>(
      MaterialPageRoute(builder: (_) => const _RegionPicker()),
    );
    if (b != null) {
      _preset(b);
    }
  }

  Future<void> _download() async {
    if (_downloading) return;
    final region = OfflineRegion(
      name:
          '${_bounds.southWest.latitude.toStringAsFixed(2)},'
          '${_bounds.southWest.longitude.toStringAsFixed(2)}',
      swLat: _bounds.southWest.latitude,
      swLon: _bounds.southWest.longitude,
      neLat: _bounds.northEast.latitude,
      neLon: _bounds.northEast.longitude,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
      downloadedAt: DateTime.now(),
    );
    setState(() {
      _downloading = true;
      // Save into the SAME source folder the browse map reads ('carto', the
      // locked basemap) so these tiles are actually served offline.
      _dl = RegionDownloader(region, source: 'carto');
      _done = 0;
      _total = region.tileCount;
    });
    await _dl!.download((done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    if (!mounted) {
      return;
    }
    if (_dl!.blocked) {
      setState(() {
        _downloading = false;
        _dl = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nguồn tải tile đã giới hạn (HTTP 429/403). Thử lại sau hoặc giảm độ chi tiết.',
          ),
        ),
      );
      return;
    }
    // Only remember the region if it actually got tiles.
    final downloaded = [..._regions, region];
    await saveRegions(downloaded);
    setState(() {
      _downloading = false;
      _dl = null;
      _regions = downloaded;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã tải xong vùng bản đồ (${region.tileCount} ô).'),
        ),
      );
    }
  }

  Future<void> _delete(OfflineRegion r) async {
    await deleteRegion(r);
    final rest = _regions.where((x) => x != r).toList();
    await saveRegions(rest);
    setState(() => _regions = rest);
  }

  @override
  Widget build(BuildContext context) {
    final preview = OfflineRegion(
      name: 'preview',
      swLat: _bounds.southWest.latitude,
      swLon: _bounds.southWest.longitude,
      neLat: _bounds.northEast.latitude,
      neLon: _bounds.northEast.longitude,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
      downloadedAt: DateTime.now(),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Dữ liệu ngoại tuyến',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // offline mode (uses only downloaded data, no internet)
          Material(
            color: const Color(0xFFE8F0FE),
            borderRadius: BorderRadius.circular(12),
            child: SwitchListTile(
              value: _forceOffline,
              onChanged: _toggleForceOffline,
              activeThumbColor: kAppBlue,
              secondary: Icon(
                _forceOffline ? Icons.cloud_off : Icons.public,
                color: _forceOffline ? kAppBlue : Colors.grey[600],
              ),
              title: const Text(
                'Chế độ ngoại tuyến',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _forceOffline
                    ? 'Đang bật — chỉ dùng dữ liệu đã tải, không gọi internet.'
                    : 'Chỉ dùng bản đồ và chỉ đường đã tải, không dùng internet.',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Bản đồ ngoại tuyến (tự động)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, size: 18, color: kAppBlue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Bản đồ đã xem được lưu tự động: '
                          '${formatBytes(_cacheBytes)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Các ô bản đồ bạn mở khi trực tuyến được giữ lại để dùng '
                    'khi ngoại tuyến (theo đúng chính sách sử dụng OSM).',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _cacheBytes > 0 ? _clearCache : null,
                      icon: const Icon(Icons.delete_sweep, size: 18),
                      label: const Text(
                        'Xoá bộ nhớ đệm',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Bản đồ dẫn đường (vector)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _navBytes > 0
                            ? Icons.map
                            : Icons.download_for_offline_outlined,
                        size: 18,
                        color: kAppBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _navBytes > 0
                              ? 'Bản đồ dẫn đường (${formatBytes(_navBytes)})'
                              : 'Chưa có bản đồ dẫn đường',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _navBytes > 0
                        ? 'Dùng trong chế độ dẫn đường — hiển thị bản đồ vector '
                              'ngoại tuyến sắc nét.'
                        : 'Tải bản đồ dẫn đường (vector) để dùng khi chỉ đường — '
                              'khoảng 29 MB cho TP.HCM. Cần cấu hình URL tải khi build '
                              '(--dart-define=NAVMAP_URL).',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  if (_navDownloading) ...[
                    LinearProgressIndicator(
                      value: _navTotal == 0 ? 0 : _navDone / _navTotal,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_navTotal == 0 ? 0 : (_navDone * 100 / _navTotal).toStringAsFixed(0)}% '
                      '(${formatBytes(_navDone)} / ${formatBytes(_navTotal)})',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _online ? _downloadNavMap : null,
                            icon: const Icon(Icons.download, size: 18),
                            label: Text(
                              _navBytes > 0 ? 'Tải lại' : 'Tải xuống',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        if (_navDownloaded) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _deleteNavMap,
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Xoá bản đồ đã tải',
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Địa hình 3D (DEM)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _terrainBytes > 0
                            ? Icons.terrain
                            : Icons.download_for_offline_outlined,
                        size: 18,
                        color: kAppBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _terrainBytes > 0
                              ? 'Địa hình 3D (${formatBytes(_terrainBytes)})'
                              : 'Chưa có dữ liệu địa hình',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _terrainBytes > 0
                        ? 'Đã tải cho vùng bên dưới — bật nút "⛰ 3D" trên màn '
                              'hình chỉ đường để thấy đồi núi nổi 3D. Cũng dùng '
                              'để tính độ cao (lên/xuống) tuyến đường khi ngoại '
                              'tuyến.'
                        : 'Tải dữ liệu độ cao (Terrarium, miễn phí) cho vùng '
                              '"Tải cả vùng" bên dưới để bản đồ dẫn đường hiển '
                              'thị đồi núi nổi 3D và tính độ cao tuyến đường khi '
                              'không có mạng.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  if (_terrainDownloading) ...[
                    LinearProgressIndicator(
                      value: _terrainTotal == 0
                          ? 0
                          : _terrainDone / _terrainTotal,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_terrainTotal == 0 ? 0 : (_terrainDone * 100 / _terrainTotal).toStringAsFixed(0)}% '
                      '($_terrainDone / $_terrainTotal ô)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _online ? _downloadTerrain : null,
                            icon: const Icon(Icons.terrain, size: 18),
                            label: Text(
                              _terrainBytes > 0 ? 'Tải lại' : 'Tải địa hình',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        if (_terrainBytes > 0) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: _deleteTerrain,
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Xoá địa hình đã tải',
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Tải cả vùng',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (tileDownloadBaseUrl.isEmpty)
            Material(
              color: const Color(0xFFFCE8E6),
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Chưa có nguồn tải tile (tileDownloadBaseUrl trống).\n\n'
                  'Bản đồ cả vùng chỉ tải được từ máy chủ tile KHÔNG phải '
                  'OpenStreetMap (để tránh bị chặn IP). Hãy trỏ nguồn khi build: '
                  'flutter build apk --dart-define=TILE_URL=https://<host>/{z}/{x}/{y}.png',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFFB3261E)),
                ),
              ),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('TP.HCM'),
                  selected: _bounds.northEast == const LatLng(10.85, 106.80),
                  onSelected: (_) => _preset(
                    LatLngBounds(
                      const LatLng(10.70, 106.60),
                      const LatLng(10.85, 106.80),
                    ),
                  ),
                ),
                ChoiceChip(
                  label: const Text('Hà Nội'),
                  selected: _bounds.northEast == const LatLng(21.10, 105.90),
                  onSelected: (_) => _preset(
                    LatLngBounds(
                      const LatLng(20.95, 105.75),
                      const LatLng(21.10, 105.90),
                    ),
                  ),
                ),
                ChoiceChip(
                  label: const Text('Đà Nẵng'),
                  selected: _bounds.northEast == const LatLng(16.10, 108.28),
                  onSelected: (_) => _preset(
                    LatLngBounds(
                      const LatLng(15.98, 108.10),
                      const LatLng(16.10, 108.28),
                    ),
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.my_location, size: 16),
                  label: const Text('Vị trí hiện tại'),
                  onPressed: _pickCurrentLocation,
                ),
                ActionChip(
                  avatar: const Icon(Icons.map, size: 16),
                  label: const Text('Chọn trên bản đồ'),
                  onPressed: _pickOnMap,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                const Text(
                  'Từ mức zoom: ',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                for (final z in [1, 3, 5, 8, 10, 12])
                  ChoiceChip(
                    label: Text('z$z'),
                    selected: _minZoom == z,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _minZoom = z),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                const Text(
                  'Độ chi tiết: ',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                for (final z in [12, 13, 14, 15, 16, 17])
                  ChoiceChip(
                    label: Text('z$z'),
                    selected: _maxZoom == z,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _maxZoom = z),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // estimate + download
            Material(
              color: const Color(0xFFF1F3F4),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${preview.tileCount} ô • ~${formatBytes(preview.estimatedBytes)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Vùng: ${_bounds.southWest.latitude.toStringAsFixed(3)},'
                      '${_bounds.southWest.longitude.toStringAsFixed(3)} → '
                      '${_bounds.northEast.latitude.toStringAsFixed(3)},'
                      '${_bounds.northEast.longitude.toStringAsFixed(3)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 6),
                    // Download source — deliberately NOT OpenStreetMap (bulk
                    // OSM downloads got this app IP-banned before).
                    Text(
                      'Nguồn tải: $tileDownloadSourceLabel '
                      '(không phải OpenStreetMap)',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 10),
                    if (_downloading) ...[
                      LinearProgressIndicator(
                        value: _total == 0 ? 0 : _done / _total,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            '$_done / $_total ô • ~'
                            '${(((_total - _done) * 1.05 / 60).ceil()).clamp(1, 999)} ph',
                            style: const TextStyle(fontSize: 12),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _dl?.cancel(),
                            child: const Text('Huỷ'),
                          ),
                        ],
                      ),
                    ] else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kAppBlue,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(44),
                          ),
                          onPressed: _online ? _download : null,
                          icon: const Icon(Icons.download),
                          label: const Text(
                            'Tải xuống vùng này',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            'Chỉ đường ngoại tuyến',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xFFF1F3F4),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _graphLoaded
                            ? Icons.check_circle
                            : (_graphHas ? Icons.folder : Icons.cloud_download),
                        size: 18,
                        color: _graphLoaded
                            ? const Color(0xFF34A853)
                            : kAppBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _graphLoaded
                              ? 'Đã nạp — định tuyến ngoại tuyến sẵn sàng'
                              : (_graphHas
                                    ? 'Bộ dữ liệu đã có (${formatBytes(_graphBytes)})'
                                    : 'Chưa có bộ dữ liệu chỉ đường'),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tải bộ dữ liệu GraphHopper (khoảng 300–500 MB cho Việt Nam) '
                    'một lần để định tuyến hoàn toàn ngoại tuyến, kể cả khi đi lệch lộ trình.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  if (graphDownloadBaseUrl.isEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Chưa cấu hình URL tải (dùng --dart-define=GRAPH_URL). '
                      'Có thể nạp bộ dữ liệu đã có trên máy bằng nút "Nạp bộ dữ liệu".',
                      style: TextStyle(fontSize: 11, color: Colors.orange[800]),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (_graphDownloading) ...[
                    LinearProgressIndicator(
                      value: _graphTotal == 0 ? 0 : _graphDone / _graphTotal,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_graphTotal == 0 ? 0 : (_graphDone * 100 / _graphTotal).toStringAsFixed(0)}% '
                      '(${formatBytes(_graphDone)} / ${formatBytes(_graphTotal)})',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _graphHas && !_graphLoading
                                ? _loadGraph
                                : null,
                            icon: _graphLoading
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.upload_file, size: 18),
                            label: const Text(
                              'Nạp bộ dữ liệu',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            // Disabled unless a GRAPH_URL was configured and
                            // no graph is present yet (and we're online).
                            onPressed:
                                _online &&
                                    !_graphHas &&
                                    graphDownloadBaseUrl.isNotEmpty
                                ? _downloadGraph
                                : null,
                            icon: const Icon(Icons.download, size: 18),
                            label: Text(
                              _graphHas ? 'Đã có' : 'Tải xuống',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Đã tải xuống',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_regions.isEmpty)
            Text(
              'Chưa có vùng nào được tải.',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            )
          else
            for (final r in _regions)
              Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.map, color: kAppBlue),
                  title: Text(
                    r.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${r.tileCount} ô • ~${formatBytes(r.estimatedBytes)} • '
                    '${r.downloadedAt.toLocal()}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(r),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Full-screen map where the visible area is the region to download.
class _RegionPicker extends StatefulWidget {
  const _RegionPicker();

  @override
  State<_RegionPicker> createState() => _RegionPickerState();
}

class _RegionPickerState extends State<_RegionPicker> {
  final MapController _map = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Chọn vùng',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(10.82, 106.63),
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: tileDownloadBaseUrl,
                userAgentPackageName: 'com.navbridge.app',
              ),
            ],
          ),
          Positioned(
            top: 8,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Text(
                  'Di chuyển và phóng to để chọn vùng cần tải, '
                  'sau đó nhấn "Dùng vùng này".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: kAppBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () =>
                  Navigator.pop(context, _map.camera.visibleBounds),
              icon: const Icon(Icons.check),
              label: const Text(
                'Dùng vùng này',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
