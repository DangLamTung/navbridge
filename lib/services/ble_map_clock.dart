/// BLE client for the **ESP32 2.8" navigation display** (ESP32_OSM_NAV
/// "NAV-OSM" board) — a parallel client to [BleClock].
///
/// Unlike the DA14585 E-ink clock this board needs no MAC-registration / key
/// handshake: it's a pure receiver. Connect, optionally read the "ready"
/// banner, then stream compact binary overlay frames ([map_protocol.dart])
/// — route / pos / nav / eta / clock — on nav updates.
///
/// The board advertises continuously (NimBLE), so a normal name/service scan
/// finds it reliably; no periodic-advertising wake-up dance needed.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:navbridge/services/ble_clock.dart'
    show ClockLink, ScannedClockDevice;

/// GATT profile of the ESP32 nav display (`ble_nav.cpp`).
abstract final class MapDisplayGatt {
  static const String serviceUuid = '5a7e1000-2b2f-4f66-9f9a-5c0f8e1a2b3c';
  static const String writeCharUuid = '5a7e1001-2b2f-4f66-9f9a-5c0f8e1a2b3c';

  /// Advertise names we accept (board = "NAV-OSM"; future boards may say
  /// "NAVMAP-ESP32").
  static const List<String> acceptedNames = ['NAV-OSM', 'NAVMAP'];
}

class BleMapClock {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  final _linkController = StreamController<ClockLink>.broadcast();
  final _scanController =
      StreamController<List<ScannedClockDevice>>.broadcast();
  final Map<String, ScannedClockDevice> _devices = {};
  ClockLink _link = ClockLink.off;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanActive = false;

  /// "NAV-OSM ready" banner read from the char on connect ('' if unavailable).
  String hello = '';

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

  Future<void> _ensureAdapterOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return;
    debugPrint('[MAP] adapter is $state — turning on...');
    try {
      await FlutterBluePlus.turnOn();
      await FlutterBluePlus.adapterState
          .firstWhere((s) => s == BluetoothAdapterState.on)
          .timeout(const Duration(seconds: 10));
      debugPrint('[MAP] adapter is on');
    } catch (e) {
      debugPrint('[MAP] failed to turn on adapter: $e');
    }
  }

  /// Start a continuous scan, streaming the accumulated device list.
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

  /// Connect to the map display. When `mac` is given (e.g. picked from a
  /// scan) connect straight to it; otherwise auto-hunt for a device
  /// advertising the NAV-OSM service or name.
  Future<void> connect({String? mac}) async {
    await disconnect();
    await stopScan();
    await _ensureAdapterOn();
    _setLink(ClockLink.connecting);
    try {
      BluetoothDevice? device;
      if (mac != null && mac.isNotEmpty) {
        debugPrint('[MAP] connecting to picked device $mac');
        device = BluetoothDevice(remoteId: DeviceIdentifier(mac));
        await device
            .connect(timeout: const Duration(seconds: 20))
            .timeout(const Duration(seconds: 25));
      } else {
        device = await _scanForMap();
        if (device == null) {
          throw Exception(
            'Không tìm thấy màn hình ESP32 — hãy bật nguồn màn hình rồi thử lại.',
          );
        }
        // discoverServices() throws when not connected — connect the scanned
        // device explicitly (same as the by-MAC path).
        debugPrint('[MAP] connecting to scanned device ${device.remoteId.str}');
        await device
            .connect(timeout: const Duration(seconds: 20))
            .timeout(const Duration(seconds: 25));
      }
      _device = device;

      await _device!.discoverServices();
      await _findCharacteristic();
      if (_write == null) {
        throw Exception(
          'Không tìm thấy Write characteristic (${MapDisplayGatt.serviceUuid})',
        );
      }
      await _readHello();
      _setLink(ClockLink.connected);
    } catch (e) {
      _setLink(ClockLink.off);
      rethrow;
    }
  }

  /// Auto-hunt the map display: it advertises continuously, so a short scan
  /// by service UUID / accepted name suffices.
  Future<BluetoothDevice?> _scanForMap({int maxAttempts = 3}) async {
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
              (u) =>
                  u.str128.toLowerCase() ==
                  MapDisplayGatt.serviceUuid.toLowerCase(),
            );
            final accepted = MapDisplayGatt.acceptedNames.any(
              (n) => name.isNotEmpty && name.contains(n.toUpperCase()),
            );
            debugPrint(
              '[MAP] scan: $mac name="$name" rssi=${r.rssi} svc=$hasService',
            );
            if (hasService || accepted) {
              if (!found.isCompleted) found.complete(d);
            }
          }
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      final device = await found.future.timeout(
        const Duration(seconds: 11),
        onTimeout: () => null,
      );
      await sub.cancel();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      if (device != null) {
        debugPrint(
          '[MAP] found display on attempt ${attempt + 1}: ${device.remoteId.str}',
        );
        return device;
      }
      debugPrint(
        '[MAP] scan attempt ${attempt + 1}/$maxAttempts: not found, retrying...',
      );
    }
    return null;
  }

  Future<void> _findCharacteristic() async {
    for (final s in _device!.servicesList) {
      if (s.uuid.str128.toLowerCase() ==
          MapDisplayGatt.serviceUuid.toLowerCase()) {
        for (final c in s.characteristics) {
          if (c.uuid.str128.toLowerCase() ==
              MapDisplayGatt.writeCharUuid.toLowerCase()) {
            _write = c;
            debugPrint(
              '[MAP] write char props: '
              'write=${c.properties.write} '
              'writeWithoutResponse=${c.properties.writeWithoutResponse}',
            );
          }
        }
      }
    }
  }

  /// Read the board's "NAV-OSM ready" banner (best-effort).
  Future<void> _readHello() async {
    final w = _write;
    if (w == null || !w.properties.read) return;
    try {
      final v = await w.read().timeout(const Duration(seconds: 5));
      hello = String.fromCharCodes(v);
      debugPrint('[MAP] hello: "$hello"');
    } catch (e) {
      debugPrint('[MAP] read hello failed: $e');
    }
  }

  /// Send a binary overlay frame, splitting it into ≤[MapChunkSize] byte
  /// writes (under the 512-byte MTU like the reference web client) and
  /// auto-selecting the write type from the stack's reported properties.
  Future<bool> sendFrame(Uint8List frame, {int chunkSize = 500}) async {
    final w = _write;
    if (w == null) return false;
    final props = w.properties;
    final preferResponse = props.write && !props.writeWithoutResponse;

    Future<bool> attempt(bool useResponse, Uint8List data) async {
      try {
        if (useResponse) {
          await w
              .write(data, withoutResponse: false)
              .timeout(const Duration(seconds: 4));
        } else {
          unawaited(w.write(data, withoutResponse: true));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return true;
      } catch (e) {
        debugPrint('[MAP] write(response=$useResponse) failed: $e');
        return false;
      }
    }

    final chunks = <Uint8List>[];
    for (var i = 0; i < frame.length; i += chunkSize) {
      chunks.add(
        Uint8List.sublistView(
          frame,
          i,
          i + chunkSize > frame.length ? frame.length : i + chunkSize,
        ),
      );
    }
    for (final chunk in chunks) {
      var ok = await attempt(preferResponse, chunk);
      if (!ok) ok = await attempt(!preferResponse, chunk);
      if (!ok) return false;
    }
    return true;
  }

  Future<void> disconnect() async {
    _scanSub?.cancel();
    _scanSub = null;
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    final dev = _device;
    _write = null;
    _device = null;
    hello = '';
    _setLink(ClockLink.off);
    try {
      await dev?.disconnect();
    } catch (_) {}
  }

  void dispose() {
    _linkController.close();
    _scanController.close();
  }
}
