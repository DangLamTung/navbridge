/// Background Bluetooth Auto-Connect service for NavBridge displays.
///
/// Automatically scans and connects to the driver's ESP32 navigation display
/// (NAV-OSM / NAVMAP) when:
///  1. The app boots or starts navigating.
///  2. Bluetooth is toggled ON on the phone.
///  3. The display powers on or comes into BLE range (auto-reconnect).
///
/// Remembers the last connected device MAC, falling back to an automatic scan
/// for known display UUIDs / names if no device has been paired yet.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/ble_map_clock.dart';

class BleAutoConnectService {
  final BleMapClock mapClock;
  final void Function(ScannedClockDevice device)? onDeviceConnected;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<ClockLink>? _mapLinkSub;

  bool _isConnecting = false;
  bool _manualDisconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  BleAutoConnectService({
    required this.mapClock,
    this.onDeviceConnected,
  });

  bool get isConnecting => _isConnecting;
  bool get isAnyConnected => mapClock.isConnected;

  /// Start background listeners for adapter state & link loss.
  void init() {
    _adapterSub?.cancel();
    _mapLinkSub?.cancel();

    // 1. When Bluetooth is turned ON, attempt auto-connect immediately.
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on && bleAutoConnect) {
        _manualDisconnect = false;
        _reconnectAttempts = 0;
        unawaited(autoConnect());
      }
    });

    // 2. Link monitoring: auto-reconnect on unexpected drop.
    _mapLinkSub = mapClock.linkStream.listen((link) {
      if (link == ClockLink.off && bleAutoConnect && !_manualDisconnect) {
        _scheduleReconnect();
      } else if (link == ClockLink.connected) {
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();
      }
    });
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _adapterSub?.cancel();
    _mapLinkSub?.cancel();
  }

  /// Called when the user taps "Disconnect" in the UI — prevents the service
  /// from aggressively reconnecting immediately.
  void notifyUserDisconnected() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
  }

  /// Re-arms auto-connect (e.g. when starting a trip, resuming app, or toggling setting).
  void rearm() {
    _manualDisconnect = false;
    _reconnectAttempts = 0;
  }

  /// Schedule a retry with backoff.
  void _scheduleReconnect() {
    if (_isConnecting || _manualDisconnect || !bleAutoConnect) return;
    _reconnectTimer?.cancel();

    // Backoff: 3s -> 6s -> 12s -> max 25s
    final delaySec = _reconnectAttempts == 0
        ? 3
        : (_reconnectAttempts == 1 ? 6 : (_reconnectAttempts == 2 ? 12 : 25));
    _reconnectAttempts++;

    debugPrint(
      '[BLE-AUTO] Link lost, reconnecting in ${delaySec}s (attempt $_reconnectAttempts)...',
    );
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (!isAnyConnected && bleAutoConnect && !_manualDisconnect) {
        unawaited(autoConnect());
      }
    });
  }

  /// Main auto-connect entry point.
  Future<bool> autoConnect({bool force = false}) async {
    if (!bleAutoConnect && !force) return false;
    if (_isConnecting || isAnyConnected) return isAnyConnected;

    _isConnecting = true;
    debugPrint('[BLE-AUTO] Starting auto-connect...');

    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        debugPrint('[BLE-AUTO] Adapter is not on ($state), skipping');
        return false;
      }

      // Phase 1: Try connecting directly to the saved MAC if available.
      final savedMac = lastBleMac.trim();

      if (savedMac.isNotEmpty) {
        debugPrint('[BLE-AUTO] Trying saved device: $savedMac');
        try {
          await mapClock.connect(mac: savedMac);
          if (mapClock.isConnected) {
            debugPrint(
              '[BLE-AUTO] Connected to saved MAP display: $savedMac',
            );
            onDeviceConnected?.call(
              ScannedClockDevice(
                id: savedMac,
                name: lastBleName.isNotEmpty ? lastBleName : 'NAV-OSM',
                rssi: 0,
              ),
            );
            _manualDisconnect = false;
            return true;
          }
        } catch (e) {
          debugPrint(
            '[BLE-AUTO] Direct connect to saved device failed: $e, falling back to scan',
          );
        }
      }

      // Phase 2: Background scan for any nearby ESP display (NAV-OSM / NAVMAP).
      debugPrint('[BLE-AUTO] Scanning for nearby displays...');
      final dev = await _scanForKnownDisplay(timeoutSec: 10);
      if (dev != null) {
        debugPrint(
          '[BLE-AUTO] Found display during scan: ${dev.id} (${dev.name})',
        );
        try {
          await mapClock.connect(mac: dev.id);
          if (mapClock.isConnected) {
            unawaited(_persistBleDevice(dev.id, dev.name, 'map'));
            onDeviceConnected?.call(dev);
            _manualDisconnect = false;
            return true;
          }
        } catch (e) {
          debugPrint('[BLE-AUTO] Connect to discovered device failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[BLE-AUTO] autoConnect error: $e');
    } finally {
      _isConnecting = false;
    }

    return isAnyConnected;
  }

  /// Helper to scan for known displays for a short duration.
  Future<ScannedClockDevice?> _scanForKnownDisplay({
    int timeoutSec = 10,
  }) async {
    final completer = Completer<ScannedClockDevice?>();

    StreamSubscription<List<ScanResult>>? sub;
    try {
      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final d = r.device;
          final name =
              (d.platformName.isNotEmpty
                      ? d.platformName
                      : r.advertisementData.advName)
                  .toUpperCase();
          final svcUuids = r.advertisementData.serviceUuids
              .map((u) => u.str128.toLowerCase())
              .toList();

          final isMap =
              name.contains('NAV-OSM') ||
              name.contains('NAVMAP') ||
              svcUuids.contains(MapDisplayGatt.serviceUuid.toLowerCase());

          if (isMap) {
            final scanned = ScannedClockDevice(
              id: d.remoteId.str,
              name: d.platformName.isNotEmpty
                  ? d.platformName
                  : r.advertisementData.advName,
              rssi: r.rssi,
            );
            if (!completer.isCompleted) {
              completer.complete(scanned);
            }
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: Duration(seconds: timeoutSec));
      final result = await completer.future.timeout(
        Duration(seconds: timeoutSec + 1),
        onTimeout: () => null,
      );
      return result;
    } catch (e) {
      debugPrint('[BLE-AUTO] scan error: $e');
      return null;
    } finally {
      await sub?.cancel();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    }
  }

  Future<void> _persistBleDevice(String mac, String name, String type) async {
    lastBleMac = mac;
    lastBleName = name;
    lastBleType = type;
    final s = await loadSettings();
    await saveSettings(
      s.copyWith(lastBleMac: mac, lastBleName: name, lastBleType: type),
    );
  }
}
