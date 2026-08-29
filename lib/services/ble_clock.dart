/// BLE client for the E-ink clock — port of the bleak handshake in
/// `scripts/test_nav_packet.py` / `scripts/nav_driver.py` using flutter_blue_plus.
///
/// Flow:
///   1. scan for the clock (name contains "EINK" or advertises the service)
///   2. connect + discover the custom service
///   3. write the 30-byte MAC registration header (2 chunks) + auth key
///   4. send navigation frames on route progress
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:navbridge/core/config.dart';
import 'package:navbridge/core/nav_protocol.dart';

/// Link state exposed to the UI (decoupled from flutter_blue_plus types).
enum ClockLink { off, connecting, connected }

/// One BLE device seen during the picker scan.
class ScannedClockDevice {
  final String id; // remoteId (MAC on Android)
  final String name;
  final int rssi;

  const ScannedClockDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
}

class BleClock {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  BluetoothCharacteristic? _indicate;
  final _linkController = StreamController<ClockLink>.broadcast();
  final _scanController =
      StreamController<List<ScannedClockDevice>>.broadcast();
  final Map<String, ScannedClockDevice> _devices = {};
  ClockLink _link = ClockLink.off;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanActive = false;

  ClockLink get link => _link;
  bool get isConnected => _link == ClockLink.connected && _write != null;
  bool get isScanning => _scanActive;

  /// Stream of link state changes for the UI.
  Stream<ClockLink> get linkStream => _linkController.stream;

  /// Live list of BLE devices seen while the picker scan is running.
  Stream<List<ScannedClockDevice>> get deviceStream => _scanController.stream;

  BluetoothDevice? get device => _device;

  void _setLink(ClockLink l) {
    _link = l;
    _linkController.add(l);
  }

  /// Make sure the Bluetooth adapter is on (itel/Transsion power management
  /// aggressively turns it off, which silently kills scans).
  Future<void> _ensureAdapterOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return;
    debugPrint('[BLE] adapter is $state — turning on...');
    try {
      await FlutterBluePlus.turnOn();
      await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on)
          .timeout(const Duration(seconds: 10));
      debugPrint('[BLE] adapter is on');
    } catch (e) {
      debugPrint('[BLE] failed to turn on adapter: $e');
    }
  }

  /// Start a continuous scan, streaming the accumulated device list.
  /// Returns once the scan is started (does NOT wait for it to end). Devices
  /// accumulate in [_devices] so results persist across adapter restarts —
  /// the picker sheet re-calls this whenever the adapter drops the scan.
  Future<void> startScan() async {
    if (_scanActive) return;
    _scanActive = true;
    await _ensureAdapterOn();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final d = r.device;
        final mac = d.remoteId.str;
        final name = d.platformName.isNotEmpty
            ? d.platformName
            : r.advertisementData.advName;
        _devices[mac] = ScannedClockDevice(id: mac, name: name, rssi: r.rssi);
      }
      if (!_scanController.isClosed) {
        _scanController.add(_devices.values.toList());
      }
    });
    // Continuous scan (no timeout) — runs until stopScan().
    unawaited(FlutterBluePlus.startScan());
  }

  Future<void> stopScan() async {
    _scanActive = false;
    await _scanSub?.cancel();
    _scanSub = null;
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  /// Connect + authenticate. Throws on failure.
  ///
  /// When `mac` is given (picked from the scan list) we connect straight to
  /// it. Otherwise we auto-hunt for the clock (it advertises only
  /// periodically).
  Future<void> connect({String? mac}) async {
    await disconnect();
    await stopScan();
    await _ensureAdapterOn();
    _setLink(ClockLink.connecting);
    try {
      BluetoothDevice? device;
      if (mac != null && mac.isNotEmpty) {
        debugPrint('[BLE] connecting to picked device $mac');
        device = BluetoothDevice(remoteId: DeviceIdentifier(mac));
        await _clearGattCache(device);
        try {
          await device.connect(timeout: const Duration(seconds: 20));
        } on Exception catch (e) {
          debugPrint('[BLE] connect to $mac failed: $e');
          throw Exception(
            'Không kết nối được — đồng hồ chưa quảng bá. Đánh thức đồng hồ '
            '(lắc/nhấn nút) rồi thử lại.',
          );
        }
      } else {
        device = await _scanForClock();
        if (device == null) {
          throw Exception(
            'Không tìm thấy đồng hồ — hãy đánh thức nó rồi thử lại',
          );
        }
        await _clearGattCache(device);
      }
      _device = device;

      await _device!.discoverServices();
      await _findCharacteristics();
      if (_write == null) {
        throw Exception(
          'Không tìm thấy Write characteristic (${AppConfig.serviceUuid})',
        );
      }
      await _setupIndicate();
      await _auth();
      _setLink(ClockLink.connected);
    } catch (e) {
      _setLink(ClockLink.off);
      rethrow;
    }
  }

  Future<BluetoothDevice?> _scanForClock({int maxAttempts = 8}) async {
    // The clock advertises only periodically (DA14585 battery saving) and only
    // when NOT already connected to the vendor app. So we keep scanning until
    // it shows up (up to ~2 min), connecting the instant it is seen. Matches
    // by MAC as well as name/service — Android scan results often carry an
    // empty name while the MAC is always present.
    final targetMac = AppConfig.clockMac.toUpperCase();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final found = Completer<BluetoothDevice?>();
      final seen = <String>{};
      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final d = r.device;
          final mac = d.remoteId.str.toUpperCase();
          if (seen.add(mac)) {
            final name =
                (d.platformName.isNotEmpty
                        ? d.platformName
                        : r.advertisementData.advName)
                    .toUpperCase();
            final hasService = r.advertisementData.serviceUuids.any(
              (u) => u.str128.toLowerCase() == AppConfig.serviceUuid,
            );
            debugPrint(
              '[BLE] scan: $mac name="$name" rssi=${r.rssi} svc=$hasService',
            );
            if (hasService ||
                (name.isNotEmpty && name.contains('EINK')) ||
                (targetMac.isNotEmpty && mac == targetMac)) {
              if (!found.isCompleted) found.complete(d);
            }
          }
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      final device = await found.future.timeout(
        const Duration(seconds: 16),
        onTimeout: () => null,
      );
      await sub.cancel();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      if (device != null) {
        debugPrint(
          '[BLE] found clock on attempt ${attempt + 1}: ${device.remoteId.str}',
        );
        return device;
      }
      debugPrint(
        '[BLE] scan attempt ${attempt + 1}/$maxAttempts: clock not advertising, keep trying...',
      );
    }
    return null;
  }

  Future<void> _findCharacteristics() async {
    for (final s in _device!.servicesList) {
      if (s.uuid.str128.toLowerCase() == AppConfig.serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid.str128.toLowerCase() == AppConfig.writeCharUuid) {
            _write = c;
            debugPrint(
              '[BLE] write char props: '
              'write=${c.properties.write} '
              'writeWithoutResponse=${c.properties.writeWithoutResponse}',
            );
          } else if (c.uuid.str128.toLowerCase() ==
              AppConfig.indicateCharUuid) {
            _indicate = c;
          }
        }
      }
    }
  }

  Future<void> _setupIndicate() async {
    final ind = _indicate;
    if (ind == null) return;
    try {
      await ind.setNotifyValue(true);
      debugPrint('[BLE] subscribed to indicate char');
    } catch (e) {
      debugPrint('[BLE] setNotifyValue failed: $e');
    }
  }

  /// Write bytes to the clock, auto-selecting the write type from the stack's
  /// reported characteristic properties.
  ///
  /// Same DA14585 char, but different Android stacks report different
  /// properties: itel/Transsion sees WRITE_NO_RESPONSE only (response writes
  /// throw "The write response is not supported"), while Lenovo sees WRITE
  /// only (no-response writes throw "The WRITE_NO_RESPONSE property is not
  /// supported"). We pick the supported type and fall back to the other on
  /// rejection. Response writes are awaited (with a timeout); no-response
  /// writes are fire-and-forget + small delay (some stacks never callback).
  Future<bool> _writeToClock(Uint8List data) async {
    final w = _write;
    if (w == null) return false;
    final props = w.properties;
    final preferResponse = props.write && !props.writeWithoutResponse;

    Future<bool> attempt(bool useResponse) async {
      try {
        if (useResponse) {
          await w
              .write(data, withoutResponse: false)
              .timeout(const Duration(seconds: 4));
        } else {
          unawaited(w.write(data, withoutResponse: true));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        return true;
      } catch (e) {
        debugPrint('[BLE] write(response=$useResponse) failed: $e');
        return false;
      }
    }

    var ok = await attempt(preferResponse);
    if (!ok) ok = await attempt(!preferResponse);
    return ok;
  }

  /// MAC registration header + auth key (matches the official app).
  Future<void> _auth() async {
    final header = Uint8List.fromList(AppConfig.macHeader);
    // 20-byte chunks (DA14585 default MTU) + auth key, in order.
    await _writeToClock(header.sublist(0, 20));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _writeToClock(header.sublist(20));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _writeToClock(Uint8List.fromList(AppConfig.authKey.codeUnits));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    debugPrint('[BLE] auth done');
  }

  /// Send a navigation frame to the clock. Returns true on success.
  Future<bool> sendNavFrame({
    required int meter,
    required int iconCode,
    required int hour,
    required int minute,
    required String text,
  }) async {
    if (_write == null) return false;
    try {
      final frame = buildNavFrame(
        meter: meter,
        iconCode: iconCode,
        hour: hour,
        minute: minute,
        text: text,
      );
      debugPrint('[BLE] nav: ${_hex(frame)} "$text" (${iconNames[iconCode]})');
      return await _writeToClock(frame);
    } catch (e) {
      debugPrint('[BLE] send failed: $e');
      return false;
    }
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

  /// Android caches GATT services; after many connect/disconnect cycles the
  /// stale cache makes the next connect fail (Android error 133). Clear it
  /// before (re)connecting. No-op elsewhere.
  Future<void> _clearGattCache(BluetoothDevice d) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await d.clearGattCache();
    } catch (_) {}
  }

  Future<void> disconnect() async {
    await stopScan();
    final d = _device;
    _write = null;
    _indicate = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
      _device = null;
    }
    _setLink(ClockLink.off);
  }

  void dispose() {
    disconnect();
    _scanController.close();
    _linkController.close();
  }
}
