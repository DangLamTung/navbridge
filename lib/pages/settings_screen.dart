/// Settings hub — organises the app's preferences into short-named group
/// pages. The ⚙ button on the map opens this; each tile leads to a dedicated
/// settings page.
///
/// Group pages:
///  - Dẫn đường — vehicle, search provider, routing engine, map/GPS/camera.
///  - Giọng nói — TTS voice, volume, wake word, riding-mode mic.
///  - Bong bóng nổi — floating widget + PiP shape.
///  - Nguồn dữ liệu — OSM / Vietmap / Google.
///  - Màn hình ngoài — Bluetooth auto-connect.
///  - Trợ lý AI — DeepSeek / Gemini keys.
///  - Ngoại tuyến — offline map/data management.
///  - Hành trình — recorded trip history.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/pages/offline_screen.dart';
import 'package:navbridge/pages/settings/ai_settings_page.dart';
import 'package:navbridge/pages/settings/bluetooth_settings_page.dart';
import 'package:navbridge/pages/settings/data_source_page.dart';
import 'package:navbridge/pages/settings/navigation_settings_page.dart';
import 'package:navbridge/pages/settings/overlay_settings_page.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/pages/settings/voice_settings_page.dart';
import 'package:navbridge/pages/trips_screen.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show isOnline, onlineStream;

/// General settings entry point — the ⚙ button on the map opens this hub.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _online = true;
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    _connSub = onlineStream().listen((o) {
      if (mounted) setState(() => _online = o);
    });
    isOnline().then((o) {
      if (mounted) setState(() => _online = o);
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  void _open(Widget page) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text(
          'Cài đặt',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _buildConnectivity(),
          const SizedBox(height: 12),
          SettingsLinkTile(
            icon: Icons.navigation,
            title: 'Dẫn đường',
            subtitle: 'Phương tiện, tìm kiếm, bản đồ, GPS',
            onTap: () => _open(const NavigationSettingsPage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.record_voice_over,
            title: 'Giọng nói',
            subtitle: 'Giọng đọc, âm lượng, wake word',
            onTap: () => _open(const VoiceSettingsPage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.speed,
            title: 'Bong bóng nổi',
            subtitle: 'Widget nổi, cửa sổ PiP',
            onTap: () => _open(const OverlaySettingsPage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.public,
            title: 'Nguồn dữ liệu',
            subtitle: 'OSM, Vietmap, Google',
            onTap: () => _open(const DataSourcePage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.bluetooth,
            title: 'Màn hình ngoài',
            subtitle: 'Tự động kết nối Bluetooth',
            onTap: () => _open(const BluetoothSettingsPage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.auto_awesome,
            title: 'Trợ lý AI',
            subtitle: 'Khoá DeepSeek / Gemini',
            color: const Color(0xFFF3E8FD),
            iconColor: const Color(0xFF7B1FA2),
            onTap: () => _open(const AiSettingsPage()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.download_for_offline,
            title: 'Ngoại tuyến',
            subtitle: 'Bản đồ vùng, địa hình 3D, bộ nhớ đệm',
            color: const Color(0xFFE8F0FE),
            onTap: () => _open(const OfflineScreen()),
          ),
          const SizedBox(height: 10),
          SettingsLinkTile(
            icon: Icons.history,
            title: 'Hành trình',
            subtitle: 'Các chuyến đã ghi — xem, chia sẻ, xoá',
            onTap: () => _open(const TripsScreen()),
          ),
        ],
      ),
    );
  }

  /// Online / offline connectivity banner.
  Widget _buildConnectivity() {
    return Material(
      color: _online ? const Color(0xFFE6F4EA) : const Color(0xFFFCE8E6),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              _online ? Icons.wifi : Icons.cloud_off,
              size: 18,
              color: _online
                  ? const Color(0xFF34A853)
                  : const Color(0xFFEA4335),
            ),
            const SizedBox(width: 8),
            Text(
              _online ? 'Đang trực tuyến' : 'Đang ngoại tuyến',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
