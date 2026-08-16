/// General settings hub — app behavior + navigation preferences.
///
/// Split out of the old monolithic `OfflineScreen`: this page owns the
/// GENERAL settings (trip history, connectivity, simple mode, data source,
/// navigation preferences, AI keys) and links to the separate
/// [OfflineScreen] for offline map/data management.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/core/ai_config.dart';
import 'package:navbridge/core/ai_key_store.dart';
import 'package:navbridge/core/settings.dart';
import 'package:navbridge/pages/offline_screen.dart';
import 'package:navbridge/pages/trips_screen.dart';
import 'package:navbridge/services/offline_tiles.dart';
import 'package:navbridge/services/vietmap_config.dart'
    show VietmapConfig, dataSource;
import 'package:navbridge/ui/widgets.dart';

/// General settings entry point — the ⚙ button on the map opens this.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _online = true;
  bool _simpleMode = false;
  String _vehicleType = 'car';
  int _speedOverride = 0;
  String _geocodingProvider = 'photon';
  String _routingEngine = 'auto';
  bool _smoothCamera = true;
  String _pipAspect = '34';
  bool _ridingMode = false;

  // --- AI assistant keys (encrypted on-device) ---
  bool _aiKeysLoaded = false;
  bool _aiHasKey = false;
  final _deepSeekCtrl = TextEditingController();
  final _geminiCtrl = TextEditingController();
  String _aiSaveStatus = '';

  @override
  void initState() {
    super.initState();
    // The globals reflect the persisted choices AND any session overrides
    // (the user may have gone online "if needed" from the map) — show that.
    setState(() {
      _simpleMode = simpleMode;
      _vehicleType = vehicleType;
      _speedOverride = speedOverride;
      _geocodingProvider = geocodingProvider;
      _routingEngine = routingEngine;
      _smoothCamera = smoothCamera;
      _pipAspect = pipAspect;
      _ridingMode = ridingMode;
    });
    onlineStream().listen((o) => setState(() => _online = o));
    isOnline().then((o) => setState(() => _online = o));
    _loadAiKeys();
  }

  /// Snapshot the current globals into a persisted [AppSettings] — keeps ALL
  /// preference fields so editing one never drops the others.
  AppSettings _currentSettings() => AppSettings(
    forceOffline: forceOffline,
    dataSource: dataSource,
    vehicleType: vehicleType,
    speedOverride: speedOverride,
    geocodingProvider: geocodingProvider,
    routingEngine: routingEngine,
    smoothCamera: smoothCamera,
    cameraAlerts: cameraAlerts,
    pipAspect: pipAspect,
    ridingMode: ridingMode,
    simpleMode: simpleMode,
  );

  Future<void> _toggleSimpleMode(bool v) async {
    setState(() {
      _simpleMode = v;
      simpleMode = v;
    });
    await saveSettings(_currentSettings());
  }

  Future<void> _setDataSource(String s) async {
    if (dataSource == s) return;
    dataSource = s;
    setState(() {});
    await saveSettings(_currentSettings());
  }

  void _setVehicleType(String v) {
    if (vehicleType == v) return;
    setState(() {
      vehicleType = v;
      _vehicleType = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  void _setSpeedOverride(int v) {
    if (speedOverride == v) return;
    setState(() {
      speedOverride = v;
      _speedOverride = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  void _setGeocodingProvider(String v) {
    if (geocodingProvider == v) return;
    setState(() {
      geocodingProvider = v;
      _geocodingProvider = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  /// Riding mode: tune voice recognition for a moving motorbike — short-
  /// command model, longer wind/engine silence tolerance, Bluetooth headset
  /// mic. Persisted (the mic behavior reads the global [ridingMode]).
  Future<void> _setRidingMode(bool v) async {
    setState(() {
      _ridingMode = v;
      ridingMode = v;
    });
    await saveSettings(_currentSettings());
  }

  void _setRoutingEngine(String v) {
    if (routingEngine == v) return;
    setState(() {
      routingEngine = v;
      _routingEngine = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  Future<void> _setSmoothCamera(bool v) async {
    setState(() {
      _smoothCamera = v;
      smoothCamera = v;
    });
    await saveSettings(_currentSettings());
  }

  void _setPipAspect(String v) {
    if (pipAspect == v) return;
    setState(() {
      pipAspect = v;
      _pipAspect = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  Future<void> _loadAiKeys() async {
    final (d, g) = await AiKeyStore.instance.read();
    if (!mounted) return;
    setState(() {
      _deepSeekCtrl.text = d ?? '';
      _geminiCtrl.text = g ?? '';
      _aiKeysLoaded = true;
      _aiHasKey = (d?.isNotEmpty ?? false) || (g?.isNotEmpty ?? false);
    });
  }

  /// Save the AI keys ENCRYPTED (secure storage), or clear them when blank.
  Future<void> _saveAiKeys() async {
    final d = _deepSeekCtrl.text.trim();
    final g = _geminiCtrl.text.trim();
    await AiKeyStore.instance.saveDeepSeek(d);
    await AiKeyStore.instance.saveGemini(g);
    if (!mounted) return;
    setState(() {
      _aiHasKey = d.isNotEmpty || g.isNotEmpty;
      _aiSaveStatus = 'Đã lưu khoá (mã hoá trên máy).';
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _aiSaveStatus = '');
    });
  }

  /// Show an "add / edit AI key" mini-form.
  Future<void> _editAiKey(String provider, TextEditingController ctrl) async {
    final newVal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Khoá $provider'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Dán khoá API ở đây'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () {
              ctrl.text = ctrl.text.trim();
              Navigator.of(ctx).pop(ctrl.text);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (newVal != null && mounted) {
      await _saveAiKeys();
    }
  }

  @override
  void dispose() {
    _deepSeekCtrl.dispose();
    _geminiCtrl.dispose();
    super.dispose();
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
          _buildOfflineTile(),
          const SizedBox(height: 12),
          _buildTripsTile(),
          const SizedBox(height: 12),
          _buildConnectivity(),
          const SizedBox(height: 12),
          _buildSimpleMode(),
          const SizedBox(height: 12),
          _buildDataSource(),
          const SizedBox(height: 16),
          _buildNavPreferences(),
          const SizedBox(height: 16),
          _buildAiSection(),
        ],
      ),
    );
  }

  // --- section builders (methods on the State so they can call the setters) --

  /// Link to the offline map/data page.
  Widget _buildOfflineTile() {
    return Material(
      color: const Color(0xFFE8F0FE),
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: const Icon(Icons.download_for_offline, color: kAppBlue),
        title: const Text(
          'Dữ liệu ngoại tuyến',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'Chế độ ngoại tuyến, bản đồ vùng, địa hình 3D, đồ thị định '
          'tuyến, bộ nhớ đệm…',
          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const OfflineScreen())),
      ),
    );
  }

  /// Trip history (view / share / delete recorded trips).
  Widget _buildTripsTile() {
    return Material(
      color: const Color(0xFFF1F3F4),
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: const Icon(Icons.history, color: kAppBlue),
        title: const Text(
          'Lịch sử hành trình',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'Các chuyến đã ghi lại — xem, chia sẻ hoặc xoá',
          style: TextStyle(fontSize: 12, color: Colors.grey[700]),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const TripsScreen())),
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

  /// Simple nav mode: no map — big arrow + voice commands only.
  Widget _buildSimpleMode() {
    return Material(
      color: const Color(0xFFF3E8FD),
      borderRadius: BorderRadius.circular(12),
      child: SwitchListTile(
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
    );
  }

  /// Data source: OSM (default, offline-capable) / Vietmap (fast VN).
  Widget _buildDataSource() {
    return Material(
      color: const Color(0xFFFEF7E0),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Nguồn dữ liệu (tìm kiếm & chỉ đường)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _SourceChoice(
                    label: 'OSM',
                    subtitle: 'Ngoại tuyến được',
                    icon: Icons.public,
                    selected: dataSource == 'osm',
                    onTap: () => _setDataSource('osm'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SourceChoice(
                    label: 'Vietmap',
                    subtitle: 'Nhanh + giao thông thật',
                    icon: Icons.traffic,
                    selected: dataSource == 'vietmap',
                    onTap: () => _setDataSource('vietmap'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Navigation preferences card: vehicle / speed override / geocoder /
  /// riding mode / routing engine / smooth camera / PiP.
  Widget _buildNavPreferences() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Tùy chọn dẫn đường',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Material(
          color: const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Phương tiện (giới hạn tốc độ mặc định)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SourceChoice(
                        label: 'Ô tô',
                        subtitle: 'Cao tốc 120',
                        icon: Icons.directions_car,
                        selected: _vehicleType == 'car',
                        onTap: () => _setVehicleType('car'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SourceChoice(
                        label: 'Xe máy',
                        subtitle: 'Trong phố 40-50',
                        icon: Icons.two_wheeler,
                        selected: _vehicleType == 'motorbike',
                        onTap: () => _setVehicleType('motorbike'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SourceChoice(
                        label: 'Xe tải',
                        subtitle: 'Cao tốc 80',
                        icon: Icons.local_shipping,
                        selected: _vehicleType == 'truck',
                        onTap: () => _setVehicleType('truck'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Giới hạn tốc độ (km/h)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Tự động'),
                      selected: _speedOverride == 0,
                      onSelected: (_) => _setSpeedOverride(0),
                      visualDensity: VisualDensity.compact,
                      selectedColor: kAppBlue,
                      labelStyle: TextStyle(
                        color: _speedOverride == 0 ? Colors.white : null,
                        fontSize: 12,
                      ),
                    ),
                    for (final v in const [40, 50, 60, 70, 80, 90, 100, 120])
                      ChoiceChip(
                        label: Text('$v'),
                        selected: _speedOverride == v,
                        onSelected: (_) => _setSpeedOverride(v),
                        visualDensity: VisualDensity.compact,
                        selectedColor: kAppBlue,
                        labelStyle: TextStyle(
                          color: _speedOverride == v ? Colors.white : null,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Ghi đè giới hạn trên mọi đường (0 = theo biển báo / loại '
                  'đường). Được gửi tới màn hình ESP32.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tìm kiếm địa điểm',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SourceChoice(
                        label: 'Photon',
                        subtitle: 'Nhanh, không cần khóa',
                        icon: Icons.bolt,
                        selected: _geocodingProvider == 'photon',
                        onTap: () => _setGeocodingProvider('photon'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SourceChoice(
                        label: 'Nominatim',
                        subtitle: 'OSM chính thức',
                        icon: Icons.public,
                        selected: _geocodingProvider == 'nominatim',
                        onTap: () => _setGeocodingProvider('nominatim'),
                      ),
                    ),
                  ],
                ),
                if (VietmapConfig.hasKeys) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _SourceChoice(
                          label: 'Vietmap',
                          subtitle: 'VN, cần khóa API',
                          icon: Icons.map,
                          selected: _geocodingProvider == 'vietmap',
                          onTap: () => _setGeocodingProvider('vietmap'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Chế độ đi xe máy (chống gió)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Nhận diện giọng nói khoan dung với tiếng gió / máy nổ '
                    'và dùng micro tai nghe Bluetooth khi có.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _ridingMode,
                  onChanged: _setRidingMode,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Công cụ tìm đường (ô tô)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SourceChoice(
                        label: 'Tự động',
                        subtitle: 'Bộ nhớ → OSRM',
                        icon: Icons.smart_toy_outlined,
                        selected: _routingEngine == 'auto',
                        onTap: () => _setRoutingEngine('auto'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SourceChoice(
                        label: 'Bộ nhớ',
                        subtitle: 'Chỉ ngoại tuyến',
                        icon: Icons.offline_pin,
                        selected: _routingEngine == 'graphhopper',
                        onTap: () => _setRoutingEngine('graphhopper'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SourceChoice(
                        label: 'OSRM',
                        subtitle: 'Luôn trực tuyến',
                        icon: Icons.cloud,
                        selected: _routingEngine == 'osrm',
                        onTap: () => _setRoutingEngine('osrm'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _smoothCamera,
                  onChanged: _setSmoothCamera,
                  activeThumbColor: kAppBlue,
                  secondary: const Icon(
                    Icons.moving,
                    color: kAppBlue,
                    size: 22,
                  ),
                  title: const Text(
                    'Chuyển động bản đồ mượt',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _smoothCamera
                        ? 'Bản đồ trượt liên tục giữa các lần GPS (1 Hz) — '
                              'như Google Maps.'
                        : 'Bản đồ nhảy theo từng lần GPS (1 Hz).',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Hướng cửa sổ nổi (PiP)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final a in const ['34', 'portrait', 'landscape']) ...[
                      Expanded(
                        child: _SourceChoice(
                          label: switch (a) {
                            '34' => '3:4',
                            'portrait' => '9:16',
                            _ => '4:3',
                          },
                          subtitle: switch (a) {
                            '34' => 'To, dễ nhìn',
                            'portrait' => 'Như điện thoại dọc',
                            _ => 'Ngang cổ điển',
                          },
                          icon: switch (a) {
                            '34' => Icons.crop_portrait,
                            'portrait' => Icons.phone_android,
                            _ => Icons.tv,
                          },
                          selected: _pipAspect == a,
                          onTap: () => _setPipAspect(a),
                        ),
                      ),
                      if (a != 'landscape') const SizedBox(width: 8),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Hướng cửa sổ nổi khi dẫn đường (đổi ngay cả khi cửa sổ '
                  'đang mở).',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// AI assistant card: encrypted DeepSeek / Gemini keys.
  Widget _buildAiSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Trợ lý AI',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Material(
          color: const Color(0xFFF3E8FD),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: Color(0xFF7B1FA2),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Hỏi AI về lộ trình, xăng, ETA, camera… '
                        '(DeepSeek hoặc Gemini)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _aiHasKey
                      ? 'Đã lưu khoá AI (mã hoá trên máy).'
                      : (AiConfig.deepSeekApiKey.isNotEmpty ||
                            AiConfig.geminiApiKey.isNotEmpty)
                      ? 'Có khoá AI từ bản build (--dart-define).'
                      : 'Chưa có khoá AI — thêm khoá DeepSeek / Gemini để '
                            'dùng trợ lý. Khoá được mã hoá trong bộ nhớ '
                            'an toàn của máy.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _aiKeysLoaded
                            ? () => _editAiKey('DeepSeek', _deepSeekCtrl)
                            : null,
                        icon: const Icon(Icons.key, size: 18),
                        label: Text(
                          _deepSeekCtrl.text.isNotEmpty
                              ? 'DeepSeek ✓'
                              : 'Khoá DeepSeek',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _aiKeysLoaded
                            ? () => _editAiKey('Gemini', _geminiCtrl)
                            : null,
                        icon: const Icon(Icons.key, size: 18),
                        label: Text(
                          _geminiCtrl.text.isNotEmpty
                              ? 'Gemini ✓'
                              : 'Khoá Gemini',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_aiSaveStatus.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _aiSaveStatus,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF188038),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Khoá được mã hoá bằng bộ nhớ an toàn của hệ điều hành '
                  '(Android Keystore / iOS Keychain), không nằm trong file '
                  'APK. Trợ lý gọi trực tiếp tới DeepSeek / Gemini.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Tappable card for a settings choice (icon + label + subtitle).
class _SourceChoice extends StatelessWidget {
  const _SourceChoice({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : Colors.grey[800];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? kAppBlue : const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: selected ? Colors.white70 : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
