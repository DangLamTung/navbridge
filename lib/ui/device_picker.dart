/// Modal bottom sheet that live-scans for nearby BLE devices and lets the
/// user pick which one to connect to (highlights NAV-OSM / NAVMAP displays).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/ble_map_clock.dart';

class DevicePickerSheet extends StatefulWidget {
  final BleMapClock mapClock;
  final Future<void> Function(ScannedClockDevice device) onPicked;

  const DevicePickerSheet({
    super.key,
    required this.mapClock,
    required this.onPicked,
  });

  @override
  State<DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<DevicePickerSheet> {
  final List<ScannedClockDevice> _devices = [];
  StreamSubscription<List<ScannedClockDevice>>? _sub;
  bool _scanning = true;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.mapClock.deviceStream.listen((list) {
      if (!mounted || _closed) return;
      setState(() {
        _devices
          ..clear()
          ..addAll(list);
      });
    });
    _scanLoop();
  }

  Future<void> _scanLoop() async {
    await widget.mapClock.startScan();
    while (mounted && !_closed) {
      if (!widget.mapClock.isScanning) {
        await widget.mapClock.startScan();
      }
      if (!mounted || _closed) return;
      setState(() => _scanning = widget.mapClock.isScanning);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  @override
  void dispose() {
    _closed = true;
    _sub?.cancel();
    widget.mapClock.stopScan();
    super.dispose();
  }

  /// The ESP 2.8" nav display advertises as NAV-OSM / NAVMAP.
  bool _isMap(ScannedClockDevice d) {
    final n = d.name.toUpperCase();
    return n.contains('NAV-OSM') || n.contains('NAVMAP');
  }

  Future<void> _pick(ScannedClockDevice d) async {
    _closed = true;
    Navigator.of(context).pop();
    await widget.onPicked(d);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [..._devices]..sort((a, b) => b.rssi.compareTo(a.rssi));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.65,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _scanning ? Icons.bluetooth_searching : Icons.bluetooth,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Thiết bị BLE gần đây',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const Spacer(),
                  if (_scanning)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Màn hình hiển thị NAV-OSM / NAVMAP — chạm để kết nối.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              if (sorted.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(
                      'Đang tìm thiết bị…',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sorted.length,
                    itemBuilder: (_, i) {
                      final d = sorted[i];
                      final isMap = _isMap(d);
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isMap ? Icons.map_outlined : Icons.devices,
                          color: isMap ? Colors.green : null,
                        ),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                d.name.isEmpty ? '(không có tên)' : d.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isMap
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (lastBleMac.isNotEmpty &&
                                d.id.toUpperCase() == lastBleMac.toUpperCase())
                              Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'Tự động kết nối',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text('${d.id}  •  ${d.rssi} dBm'),
                        trailing: isMap
                            ? const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 18,
                              )
                            : null,
                        onTap: () => _pick(d),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
