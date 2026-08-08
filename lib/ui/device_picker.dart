/// Modal bottom sheet that live-scans for nearby BLE devices and lets the
/// user pick which one to connect to. The E-ink clock advertises only
/// periodically, so the scan keeps restarting while the sheet is open (it
/// highlights anything named *EINK* or matching the configured MAC).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/services/ble_clock.dart';
import 'package:navbridge/core/config.dart';

class DevicePickerSheet extends StatefulWidget {
  final BleClock clock;
  final Future<void> Function(ScannedClockDevice device) onPicked;

  const DevicePickerSheet({
    super.key,
    required this.clock,
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
    _sub = widget.clock.deviceStream.listen((list) {
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
    // Continuous scan; restart it whenever the adapter drops it (itel OS
    // aggressively powers Bluetooth off, killing the scan).
    await widget.clock.startScan();
    while (mounted && !_closed) {
      if (!widget.clock.isScanning) {
        await widget.clock.startScan();
      }
      setState(() => _scanning = widget.clock.isScanning);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  @override
  void dispose() {
    _closed = true;
    _sub?.cancel();
    widget.clock.stopScan();
    super.dispose();
  }

  bool _isClock(ScannedClockDevice d) {
    final n = d.name.toUpperCase();
    return n.contains('EINK') ||
        d.id.toUpperCase() == AppConfig.clockMac.toUpperCase();
  }

  /// The ESP 2.8" nav display advertises as NAV-OSM / NAVMAP. It has its own
  /// GATT profile and must be driven by the map BLE client — not the E-ink
  /// clock's, whose Write characteristic UUID it does not expose.
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
                'Đồng hồ E-ink chỉ quảng bá định kỳ — giữ màn hình này mở '
                'cho đến khi thấy nó rồi chạm để kết nối.',
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
                      final isClock = _isClock(d);
                      final isMap = _isMap(d);
                      final target = isClock || isMap;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isClock
                              ? Icons.watch
                              : isMap
                              ? Icons.map_outlined
                              : Icons.devices,
                          color: target ? Colors.green : null,
                        ),
                        title: Text(
                          d.name.isEmpty ? '(không có tên)' : d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: target
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text('${d.id}  •  ${d.rssi} dBm'),
                        trailing: target
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
