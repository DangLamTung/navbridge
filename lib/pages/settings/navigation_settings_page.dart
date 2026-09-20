/// "Dẫn đường" settings page — vehicle, search provider, routing engine and
/// the map/GPS/camera display preferences.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/core/settings.dart' show gpsFilterStrength;
import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show
        vehicleType,
        geocodingProvider,
        routingEngine,
        smoothCamera,
        cameraAlerts,
        gpsFilter,
        simpleMode,
        navSpeedStyle;
import 'package:navbridge/ui/widgets.dart';

class NavigationSettingsPage extends StatefulWidget {
  const NavigationSettingsPage({super.key});

  @override
  State<NavigationSettingsPage> createState() => _NavigationSettingsPageState();
}

class _NavigationSettingsPageState extends State<NavigationSettingsPage> {
  bool _simpleMode = false;
  bool _smoothCamera = true;
  bool _cameraAlerts = true;
  bool _gpsFilter = true;
  String _gpsFilterStrength = 'standard';

  /// 'chip' | 'dial' — see [navSpeedStyle]. Defaults to the dial.
  String _navSpeedStyle = 'dial';

  @override
  void initState() {
    super.initState();
    _simpleMode = simpleMode;
    _smoothCamera = smoothCamera;
    _cameraAlerts = cameraAlerts;
    _gpsFilter = gpsFilter;
    _gpsFilterStrength = gpsFilterStrength;
    _navSpeedStyle = navSpeedStyle;
  }

  Future<void> _setNavSpeedStyle(String v) async {
    if (v == _navSpeedStyle) return;
    setState(() {
      _navSpeedStyle = v;
      navSpeedStyle = v;
    });
    await saveAllSettings();
  }

  void _setGpsFilterStrength(String v) {
    if (gpsFilterStrength == v) return;
    setState(() {
      _gpsFilterStrength = v;
      gpsFilterStrength = v;
    });
    unawaited(saveAllSettings());
  }

  void _setVehicleType(String v) {
    if (vehicleType == v) return;
    setState(() => vehicleType = v);
    unawaited(saveAllSettings());
  }

  void _setGeocodingProvider(String v) {
    if (geocodingProvider == v) return;
    setState(() => geocodingProvider = v);
    unawaited(saveAllSettings());
  }

  void _setRoutingEngine(String v) {
    if (routingEngine == v) return;
    setState(() => routingEngine = v);
    unawaited(saveAllSettings());
  }

  Future<void> _setSmoothCamera(bool v) async {
    setState(() {
      _smoothCamera = v;
      smoothCamera = v;
    });
    await saveAllSettings();
  }

  Future<void> _setCameraAlerts(bool v) async {
    setState(() {
      _cameraAlerts = v;
      cameraAlerts = v;
    });
    await saveAllSettings();
  }

  Future<void> _toggleGpsFilter(bool v) async {
    setState(() {
      _gpsFilter = v;
      gpsFilter = v;
    });
    await saveAllSettings();
  }

  Future<void> _toggleSimpleMode(bool v) async {
    setState(() {
      _simpleMode = v;
      simpleMode = v;
    });
    await saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Dẫn đường',
      children: [
        // --- Vehicle (default speed limits) ---
        const SettingsSection('Phương tiện (giới hạn tốc độ mặc định)'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SettingsChoice(
                      label: 'Ô tô',
                      subtitle: 'Cao tốc 120',
                      icon: Icons.directions_car,
                      selected: vehicleType == 'car',
                      onTap: () => _setVehicleType('car'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
                      label: 'Xe máy',
                      subtitle: 'Trong phố 40-50',
                      icon: Icons.two_wheeler,
                      selected: vehicleType == 'motorbike',
                      onTap: () => _setVehicleType('motorbike'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
                      label: 'Xe tải',
                      subtitle: 'Cao tốc 80',
                      icon: Icons.local_shipping,
                      selected: vehicleType == 'truck',
                      onTap: () => _setVehicleType('truck'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Geocoding provider ---
        const SettingsSection('Tìm kiếm địa điểm'),
        SettingsCard(
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            // Taller cells (2.5 overflowed the choice card on the itel's
            // narrow screen — RenderFlex overflow at the bottom).
            childAspectRatio: 1.6,
            children: [
              SettingsChoice(
                label: 'Google Maps',
                subtitle: 'Chuẩn, cần khóa API',
                icon: Icons.place,
                selected: geocodingProvider == 'google',
                onTap: () => _setGeocodingProvider('google'),
              ),
              SettingsChoice(
                label: 'Vietmap',
                subtitle: 'VN, cần khóa API',
                icon: Icons.map,
                selected: geocodingProvider == 'vietmap',
                onTap: () => _setGeocodingProvider('vietmap'),
              ),
              SettingsChoice(
                label: 'Photon',
                subtitle: 'Nhanh, không cần khóa',
                icon: Icons.bolt,
                selected: geocodingProvider == 'photon',
                onTap: () => _setGeocodingProvider('photon'),
              ),
              SettingsChoice(
                label: 'Nominatim',
                subtitle: 'OSM chính thức',
                icon: Icons.public,
                selected: geocodingProvider == 'nominatim',
                onTap: () => _setGeocodingProvider('nominatim'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Routing engine ---
        const SettingsSection('Công cụ tìm đường (ô tô)'),
        SettingsCard(
          child: Row(
            children: [
              Expanded(
                child: SettingsChoice(
                  label: 'Tự động',
                  subtitle: 'Bộ nhớ → OSRM',
                  icon: Icons.smart_toy_outlined,
                  selected: routingEngine == 'auto',
                  onTap: () => _setRoutingEngine('auto'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SettingsChoice(
                  label: 'Bộ nhớ',
                  subtitle: 'Chỉ ngoại tuyến',
                  icon: Icons.offline_pin,
                  selected: routingEngine == 'graphhopper',
                  onTap: () => _setRoutingEngine('graphhopper'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SettingsChoice(
                  label: 'OSRM',
                  subtitle: 'Luôn trực tuyến',
                  icon: Icons.cloud,
                  selected: routingEngine == 'osrm',
                  onTap: () => _setRoutingEngine('osrm'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Map / GPS / camera toggles ---
        const SettingsSection('Bản đồ & GPS'),
        SettingsCard(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _smoothCamera,
                onChanged: _setSmoothCamera,
                activeThumbColor: kAppBlue,
                secondary: const Icon(Icons.moving, color: kAppBlue, size: 22),
                title: const Text(
                  'Chuyển động bản đồ mượt',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _smoothCamera
                      ? 'Bản đồ trượt liên tục giữa các lần GPS (1 Hz) — như Google Maps.'
                      : 'Bản đồ nhảy theo từng lần GPS (1 Hz).',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _gpsFilter,
                onChanged: _toggleGpsFilter,
                activeThumbColor: kAppBlue,
                secondary: const Icon(
                  Icons.filter_alt,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Lọc GPS (chống nhảy vị trí)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _gpsFilter
                      ? 'Chặn fix GPS bất thường (nhảy vị trí / tốc độ ảo) trước khi vẽ lên bản đồ.'
                      : 'Dùng GPS thô — không chặn fix nào (vị trí có thể nhảy, tốc độ có thể sai).',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
              if (_gpsFilter) ...[
                const SizedBox(height: 8),
                const Text(
                  'Độ lọc GPS',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: SettingsChoice(
                        label: 'Nhẹ',
                        subtitle: 'Ít chặn',
                        icon: Icons.tune,
                        selected: _gpsFilterStrength == 'light',
                        onTap: () => _setGpsFilterStrength('light'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SettingsChoice(
                        label: 'Chuẩn',
                        subtitle: 'Cân bằng',
                        icon: Icons.balance,
                        selected: _gpsFilterStrength == 'standard',
                        onTap: () => _setGpsFilterStrength('standard'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SettingsChoice(
                        label: 'Mạnh',
                        subtitle: 'Chặn nhiều',
                        icon: Icons.security,
                        selected: _gpsFilterStrength == 'strong',
                        onTap: () => _setGpsFilterStrength('strong'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Nhẹ giữ nhiều fix (chấp nhận nhiễu), Mạnh chặn nhiều fix bất thường hơn (vị trí có thể chậm hơn một nhịp).',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _cameraAlerts,
                onChanged: _setCameraAlerts,
                activeThumbColor: kAppBlue,
                activeTrackColor: const Color(0xFFD93025),
                secondary: const Icon(
                  Icons.videocam,
                  color: Color(0xFFD93025),
                  size: 22,
                ),
                title: const Text(
                  'Cảnh báo camera phạt nguội',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _cameraAlerts
                      ? 'Báo bằng giọng nói khi tới gần camera và hiển thị chấm camera trên bản đồ.'
                      : 'Tắt cảnh báo + ẩn camera trên bản đồ.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Speed display style -------------------------------------------
        const SettingsSection('Hiển thị tốc độ'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Cách hiển thị tốc độ hiện tại + biển giới hạn khi đang dẫn đường.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'chip',
                    label: Text('Nhỏ gọn', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.badge_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: 'dial',
                    label: Text(
                      'Đồng hồ widget',
                      style: TextStyle(fontSize: 12),
                    ),
                    icon: Icon(Icons.speed, size: 16),
                  ),
                ],
                selected: {_navSpeedStyle},
                onSelectionChanged: (s) => unawaited(_setNavSpeedStyle(s.first)),
              ),
              const SizedBox(height: 6),
              Text(
                _navSpeedStyle == 'dial'
                    ? 'Đồng hồ tròn như widget nổi: vạch cam→đỏ chạy theo tốc độ, số lớn ở giữa, biển giới hạn chồng góc phải.'
                    : 'Chip trắng: tốc độ + biển giới hạn dạng hai vòng tròn nhỏ cạnh tên đường.',
                style: TextStyle(fontSize: 11, color: Colors.grey[700]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Simple mode ---
        const SettingsSection('Hiển thị dẫn đường'),
        SettingsCard(
          color: const Color(0xFFF3E8FD),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _simpleMode,
            onChanged: _toggleSimpleMode,
            activeThumbColor: kAppBlue,
            secondary: Icon(
              _simpleMode ? Icons.navigation : Icons.navigation_outlined,
              color: _simpleMode ? const Color(0xFF7B1FA2) : Colors.grey[600],
            ),
            title: const Text(
              'Chế độ đơn giản (không bản đồ)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _simpleMode
                  ? 'Đang bật — mũi tên lớn + giọng nói, không hiện bản đồ.'
                  : 'Chỉ đường bằng mũi tên lớn + giọng nói, không hiện bản đồ.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ),
        ),
      ],
    );
  }
}
