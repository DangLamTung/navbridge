/// "Màn hình ngoài" settings page — Bluetooth auto-connect for the external
/// E-ink / NAV-OSM display and the remembered device.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/settings.dart';
import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/ui/widgets.dart';

class BluetoothSettingsPage extends StatefulWidget {
  const BluetoothSettingsPage({super.key});

  @override
  State<BluetoothSettingsPage> createState() => _BluetoothSettingsPageState();
}

class _BluetoothSettingsPageState extends State<BluetoothSettingsPage> {
  bool _bleAutoConnect = true;
  String _lastBleMac = '';
  String _lastBleName = '';

  @override
  void initState() {
    super.initState();
    _bleAutoConnect = bleAutoConnect;
    _lastBleMac = lastBleMac;
    _lastBleName = lastBleName;
  }

  Future<void> _toggleBleAutoConnect(bool v) async {
    setState(() {
      _bleAutoConnect = v;
      bleAutoConnect = v;
    });
    await saveAllSettings();
  }

  Future<void> _clearRememberedBleDevice() async {
    setState(() {
      _lastBleMac = '';
      _lastBleName = '';
      lastBleMac = '';
      lastBleName = '';
      lastBleType = 'auto';
    });
    await saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Màn hình ngoài',
      children: [
        const SettingsSection('Bluetooth'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _bleAutoConnect,
                onChanged: _toggleBleAutoConnect,
                activeThumbColor: kAppBlue,
                secondary: const Icon(
                  Icons.bluetooth_searching,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Tự động kết nối Bluetooth',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _bleAutoConnect
                      ? 'Tự động quét & kết nối với màn hình NAV-OSM khi mở app hoặc khi ở gần.'
                      : 'Tắt tự động kết nối — bạn cần chọn kết nối thủ công '
                            'trên bản đồ.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
              const Divider(height: 16),
              if (_lastBleMac.isNotEmpty) ...[
                Row(
                  children: [
                    Icon(
                      Icons.tv,
                      size: 20,
                      color: Colors.green[700],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _lastBleName.isNotEmpty
                                ? _lastBleName
                                : 'Màn hình NAV-OSM',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'MAC: $_lastBleMac • Đã lưu tự kết nối',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _clearRememberedBleDevice,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Quên',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Chưa lưu thiết bị cụ thể. Khi bật tự động kết nối, app '
                        'sẽ tự tìm kiếm màn hình NAV-OSM gần bạn.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
