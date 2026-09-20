/// Full-screen viewer that re-draws a recorded trip on the map (Google
/// Timeline style): the GPS path as a blue polyline, a green start marker and
/// a red end marker, plus the visited stops/places as blue pins.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:navbridge/services/fuel_log.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show vehicleType, OfflineTileProvider;
import 'package:navbridge/services/trip_logger.dart';
import 'package:navbridge/ui/widgets.dart';

class TripMapScreen extends StatefulWidget {
  final File file;

  const TripMapScreen({super.key, required this.file});

  @override
  State<TripMapScreen> createState() => _TripMapScreenState();
}

class _TripMapScreenState extends State<TripMapScreen> {
  LoadedTrip? _trip;
  List<FuelEntry> _fuelLog = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await loadTrip(widget.file);
    final log = await loadFuelLog();
    if (!mounted) return;
    setState(() {
      _trip = t;
      _fuelLog = log;
      _loading = false;
    });
  }

  /// Litres manually logged against this trip.
  double _tripFuelLiters() => fuelLitersForTrip(_fuelLog, widget.file.path);

  /// Number of manual refuels logged against this trip.
  int _tripFuelStops() => fuelStopsForTrip(_fuelLog, widget.file.path);

  /// Ask the driver how much gas they put in and log it against this trip.
  Future<void> _addFuel() async {
    final litersCtrl = TextEditingController();
    final costCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ghi đổ xăng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: litersCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Số lít *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: costCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Tiền (đ) — tuỳ chọn',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final liters = double.tryParse(litersCtrl.text);
    if (liters == null || liters <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nhập số lít hợp lệ.')),
      );
      return;
    }
    final cost = double.tryParse(costCtrl.text);
    final updated = await addFuelEntry(
      FuelEntry(
        time: DateTime.now(),
        liters: liters,
        cost: cost,
        tripFile: widget.file.path,
      ),
    );
    if (!mounted) return;
    setState(() => _fuelLog = updated);
  }

  LatLngBounds? _boundsOf(List<LatLng> path) {
    if (path.isEmpty) return null;
    var latMin = path.first.latitude, latMax = path.first.latitude;
    var lngMin = path.first.longitude, lngMax = path.first.longitude;
    for (final p in path) {
      if (p.latitude < latMin) latMin = p.latitude;
      if (p.latitude > latMax) latMax = p.latitude;
      if (p.longitude < lngMin) lngMin = p.longitude;
      if (p.longitude > lngMax) lngMax = p.longitude;
    }
    return LatLngBounds(LatLng(latMin, lngMin), LatLng(latMax, lngMax));
  }

  Widget _pin(IconData icon, Color color, {double size = 36}) {
    return Icon(
      icon,
      color: color,
      size: size,
      shadows: const [Shadow(color: Colors.black38, blurRadius: 4)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _trip;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: Text(
          t?.name ?? 'Chuyến đi',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
        ),
        actions: [
          IconButton(
            tooltip: 'Ghi đổ xăng',
            icon: const Icon(Icons.local_gas_station),
            onPressed: _addFuel,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (t == null || t.path.isEmpty)
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Chuyến đi này không có dữ liệu vị trí.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.blueGrey),
                    ),
                  ),
                )
              : _mapView(t),
    );
  }

  Widget _mapView(LoadedTrip t) {
    final bounds = _boundsOf(t.path);
    final degenerate =
        bounds != null &&
        bounds.southWest.latitude == bounds.northEast.latitude &&
        bounds.southWest.longitude == bounds.northEast.longitude;

    final options = degenerate
        ? MapOptions(
            initialCenter: t.path.first,
            initialZoom: 15,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
          )
        : MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: bounds!,
              padding: const EdgeInsets.all(48),
            ),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
          );

    return Stack(
      children: [
        FlutterMap(
          options: options,
          children: [
            TileLayer(
              urlTemplate:
                  'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
              userAgentPackageName: 'com.navbridge.app',
              // Serve cached offline tiles first, then fall back to network.
              // ESRI World Street Map is used because OSM/CARTO tile hosts are
              // blocked / need an API key on some devices.
              tileProvider: OfflineTileProvider(source: 'esri-street'),
            ),
            PolylineLayer(
              polylines: [
                Polyline(points: t.path, color: kAppBlue, strokeWidth: 5),
              ],
            ),
            MarkerLayer(
              markers: [
                // Start.
                Marker(
                  point: t.path.first,
                  width: 38,
                  height: 38,
                  child: _pin(Icons.trip_origin, Colors.green),
                ),
                // End.
                Marker(
                  point: t.path.last,
                  width: 38,
                  height: 38,
                  child: _pin(Icons.location_pin, Colors.red),
                ),
                // Visited places.
                for (final p in t.places)
                  Marker(
                    point: LatLng(p.lat, p.lng),
                    width: 34,
                    height: 34,
                    child: _pin(Icons.place, Colors.blue, size: 34),
                  ),
              ],
            ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: _statsCard(t),
        ),
      ],
    );
  }

  /// Bottom summary card: distance, duration, average speed, fuel.
  Widget _statsCard(LoadedTrip t) {
    final km = t.distanceKm;
    final dur = t.duration;
    final avg = t.avgSpeedKmh;
    // Manual fuel log wins; then detected gas-station stops; then estimate.
    final manualLiters = _tripFuelLiters();
    final manualStops = _tripFuelStops();
    final gasStops = gasStationStopCount(t);
    final String fuelValue;
    final String fuelLabel;
    if (manualStops > 0) {
      fuelValue = '${manualLiters.toStringAsFixed(1)} L';
      fuelLabel = 'Đã đổ xăng ($manualStops lần)';
    } else if (gasStops > 0) {
      fuelValue = '$gasStops lần';
      fuelLabel = 'Đổ xăng';
    } else {
      fuelValue = '~${t.estimatedFuelL(vehicleType).toStringAsFixed(1)} L';
      fuelLabel = 'Ước tính xăng';
    }
    return Card(
      elevation: 3,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _statItem(Icons.route, '${km.toStringAsFixed(1)} km', 'Quãng đường'),
            _statItem(Icons.schedule, _fmtDuration(dur), 'Thời gian'),
            _statItem(
              Icons.speed,
              avg == null ? '—' : '${avg.toStringAsFixed(0)} km/h',
              'Tốc độ TB',
            ),
            _statItem(Icons.local_gas_station, fuelValue, fuelLabel),
          ],
        ),
      ),
    );
  }

  Widget _statItem(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: kAppBlue, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
        ),
      ],
    );
  }

  String _fmtDuration(Duration? d) {
    if (d == null) return '—';
    final h = d.inHours, m = d.inMinutes % 60;
    if (h > 0) return '$h giờ $m phút';
    return '$m phút';
  }
}
