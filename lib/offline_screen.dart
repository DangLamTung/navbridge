/// Offline map management: pick a region (preset / current view / current
/// location), see the estimated size, download with progress, and delete
/// downloaded regions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'offline_tiles.dart';
import 'ui/widgets.dart';

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
  LatLngBounds _bounds =
      LatLngBounds(const LatLng(10.70, 106.60), const LatLng(10.85, 106.80)); // HCMC core
  int _maxZoom = 16;
  bool _online = true;
  bool _downloading = false;
  RegionDownloader? _dl;
  int _done = 0;
  int _total = 1;

  @override
  void initState() {
    super.initState();
    _reload();
    onlineStream().listen((o) => setState(() => _online = o));
    isOnline().then((o) => setState(() => _online = o));
  }

  Future<void> _reload() async {
    final r = await loadRegions();
    if (mounted) {
      setState(() => _regions = r);
    }
  }

  void _preset(LatLngBounds b) => setState(() => _bounds = b);

  Future<void> _pickCurrentLocation() async {
    LatLng? pos;
    try {
      final p = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
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
            const SnackBar(content: Text('Không lấy được vị trí hiện tại.')));
      }
      return;
    }
    const km = 0.009; // ~1 km per degree
    _preset(LatLngBounds(
        LatLng(pos.latitude - 5 * km, pos.longitude - 5 * km),
        LatLng(pos.latitude + 5 * km, pos.longitude + 5 * km)));
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
      name: '${_bounds.southWest.latitude.toStringAsFixed(2)},'
          '${_bounds.southWest.longitude.toStringAsFixed(2)}',
      swLat: _bounds.southWest.latitude,
      swLon: _bounds.southWest.longitude,
      neLat: _bounds.northEast.latitude,
      neLon: _bounds.northEast.longitude,
      minZoom: 13,
      maxZoom: _maxZoom,
      downloadedAt: DateTime.now(),
    );
    setState(() {
      _downloading = true;
      _dl = RegionDownloader(region);
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'OSM đã giới hạn tải (429). Thử lại sau hoặc giảm độ chi tiết.')));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Đã tải xong vùng bản đồ (${region.tileCount} ô).')));
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
      minZoom: 13,
      maxZoom: _maxZoom,
      downloadedAt: DateTime.now(),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Bản đồ ngoại tuyến',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // connectivity
          Material(
            color: _online ? const Color(0xFFE6F4EA) : const Color(0xFFFCE8E6),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(_online ? Icons.wifi : Icons.cloud_off,
                    size: 18,
                    color: _online ? const Color(0xFF34A853) : const Color(0xFFEA4335)),
                const SizedBox(width: 8),
                Text(_online ? 'Đang trực tuyến' : 'Đang ngoại tuyến',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Vùng bản đồ',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('TP.HCM'),
                selected: _bounds.northEast == const LatLng(10.85, 106.80),
                onSelected: (_) => _preset(
                    LatLngBounds(const LatLng(10.70, 106.60), const LatLng(10.85, 106.80))),
              ),
              ChoiceChip(
                label: const Text('Hà Nội'),
                selected: _bounds.northEast == const LatLng(21.10, 105.90),
                onSelected: (_) => _preset(
                    LatLngBounds(const LatLng(20.95, 105.75), const LatLng(21.10, 105.90))),
              ),
              ChoiceChip(
                label: const Text('Đà Nẵng'),
                selected: _bounds.northEast == const LatLng(16.10, 108.28),
                onSelected: (_) => _preset(
                    LatLngBounds(const LatLng(15.98, 108.10), const LatLng(16.10, 108.28))),
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
          Row(children: [
            const Text('Độ chi tiết: ',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            for (final z in [14, 15, 16, 17])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('z$z'),
                  selected: _maxZoom == z,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _maxZoom = z),
                ),
              ),
          ]),
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
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Vùng: ${_bounds.southWest.latitude.toStringAsFixed(3)},'
                    '${_bounds.southWest.longitude.toStringAsFixed(3)} → '
                    '${_bounds.northEast.latitude.toStringAsFixed(3)},'
                    '${_bounds.northEast.longitude.toStringAsFixed(3)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 10),
                  if (_downloading) ...[
                    LinearProgressIndicator(value: _total == 0 ? 0 : _done / _total),
                    const SizedBox(height: 6),
                    Row(children: [
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
                    ]),
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
                        label: const Text('Tải xuống vùng này',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Đã tải xuống',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_regions.isEmpty)
            Text('Chưa có vùng nào được tải.',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]))
          else
            for (final r in _regions)
              Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.map, color: kAppBlue),
                  title: Text(r.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${r.tileCount} ô • ~${formatBytes(r.estimatedBytes)} • '
                      '${r.downloadedAt.toLocal()}'),
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
        title: const Text('Chọn vùng',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(10.82, 106.63),
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
              label: const Text('Dùng vùng này',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
