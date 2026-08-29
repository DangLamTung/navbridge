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
import 'package:navbridge/services/overlay_visibility.dart';
import 'package:navbridge/services/overlay_widget.dart';
import 'package:navbridge/services/vietmap_config.dart' show dataSource;
import 'package:navbridge/ui/overlay_layout_screen.dart';
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
  String _geocodingProvider = 'photon';
  String _routingEngine = 'auto';
  bool _smoothCamera = true;
  bool _cameraAlerts = true;
  bool _gpsFilter = true;
  bool _overlayOn = false; // floating speed/limit widget over other apps
  String _overlayLayout = 'vertical'; // floating widget layout id
  double _overlayScale = 1.0;
  String _pipAspect = '34';
  bool _ridingMode = false;
  double _voiceVolume = 1.0;
  bool _bleAutoConnect = true;
  String _lastBleMac = '';
  String _lastBleName = '';
  String _lastBleType = 'auto';
  final _wakeWordCtrl = TextEditingController();

  // --- AI assistant keys (encrypted on-device) ---
  bool _aiKeysLoaded = false;
  bool _aiHasKey = false;
  final _deepSeekCtrl = TextEditingController();
  final _geminiCtrl = TextEditingController();
  String _aiSaveStatus = '';
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    // The globals reflect the persisted choices AND any session overrides
    // (the user may have gone online "if needed" from the map) — show that.
    _simpleMode = simpleMode;
    _vehicleType = vehicleType;
    _geocodingProvider = geocodingProvider;
    _routingEngine = routingEngine;
    _smoothCamera = smoothCamera;
    _cameraAlerts = cameraAlerts;
    _gpsFilter = gpsFilter;
    _overlayLayout = overlayLayout;
    _overlayScale = overlayScale;
    _pipAspect = pipAspect;
    _ridingMode = ridingMode;
    _voiceVolume = voiceVolume;
    _bleAutoConnect = bleAutoConnect;
    _lastBleMac = lastBleMac;
    _lastBleName = lastBleName;
    _lastBleType = lastBleType;
    _wakeWordCtrl.text = wakeWord;
    _connSub = onlineStream().listen((o) {
      if (mounted) setState(() => _online = o);
    });
    isOnline().then((o) {
      if (mounted) setState(() => _online = o);
    });
    _loadAiKeys();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _wakeWordCtrl.dispose();
    _deepSeekCtrl.dispose();
    _geminiCtrl.dispose();
    super.dispose();
  }

  /// Snapshot the current globals into a persisted [AppSettings] — keeps ALL
  /// preference fields so editing one never drops the others.
  AppSettings _currentSettings() => AppSettings(
    forceOffline: forceOffline,
    dataSource: dataSource,
    vehicleType: vehicleType,
    geocodingProvider: geocodingProvider,
    routingEngine: routingEngine,
    smoothCamera: smoothCamera,
    cameraAlerts: cameraAlerts,
    gpsFilter: gpsFilter,
    radar: radarOn,
    pipAspect: pipAspect,
    ridingMode: ridingMode,
    voiceVolume: voiceVolume,
    simpleMode: simpleMode,
    wakeWord: wakeWord,
    overlayLayout: overlayLayout,
    overlayScale: overlayScale,
    bleAutoConnect: bleAutoConnect,
    lastBleMac: lastBleMac,
    lastBleName: lastBleName,
    lastBleType: lastBleType,
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

  /// Edit the always-on voice assistant wake word (custom per device — set
  /// whatever word this phone's recognizer actually hears).
  Future<void> _editWakeWord() async {
    final newVal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Từ khoá đánh thức'),
        content: TextField(
          controller: _wakeWordCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ví dụ: nav, ok, hey'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () {
              _wakeWordCtrl.text = _wakeWordCtrl.text.trim();
              Navigator.of(ctx).pop(_wakeWordCtrl.text);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (newVal == null || !mounted) return;
    setState(() => wakeWord = newVal.isEmpty ? 'nav' : newVal);
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

  /// Speed/red-light camera alerts (phạt nguội DB): voice announce when a
  /// camera is ~600 m ahead + camera markers on the map. Shared with the
  /// on-map videocam toggle; persisted.
  Future<void> _setCameraAlerts(bool v) async {
    setState(() {
      _cameraAlerts = v;
      cameraAlerts = v;
    });
    await saveSettings(_currentSettings());
  }

  /// GPS outlier filter (innovation gate): reject bad fixes (too inaccurate /
  /// position jumping) before they reach the map, filter and speed chip.
  /// Off → raw GPS passes through with no fixes dropped.
  Future<void> _toggleGpsFilter(bool v) async {
    setState(() {
      _gpsFilter = v;
      gpsFilter = v;
    });
    await saveSettings(_currentSettings());
  }

  /// Spoken guidance volume (0..1), persisted.
  Future<void> _setVoiceVolume(double v) async {
    setState(() {
      _voiceVolume = v;
      voiceVolume = v;
    });
    await saveSettings(_currentSettings());
  }

  /// Floating speed-limit / camera widget over other apps (Waze-Mod style):
  /// requests the "display over other apps" permission and shows/hides the
  /// self-contained overlay widget.
  Future<void> _setOverlay(bool v) async {
    if (v) {
      await startOverlay();
      if (!mounted) return;
      final granted = await overlayPermissionGranted();
      if (mounted) setState(() => _overlayOn = granted);
    } else {
      await stopOverlay();
      if (mounted) setState(() => _overlayOn = false);
    }
  }

  /// Open the floating-widget layout chooser page.
  Future<void> _openOverlayLayout() async {
    final picked = await Navigator.of(context).push<OverlayLayoutResult>(
      MaterialPageRoute(
        builder: (_) =>
            OverlayLayoutScreen(selected: _overlayLayout, scale: _overlayScale),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _overlayLayout = picked.layout;
        overlayLayout = picked.layout;
        _overlayScale = picked.scale;
        overlayScale = picked.scale;
      });
      await saveSettings(_currentSettings());
      // Push the new layout + scale to the RUNNING overlay and resize its
      // window NOW. Previously this only saved the setting — the bubble kept
      // the old layout at the old window size until the next navigation sync,
      // so the new "Nằm ngang" content was clipped/overlapped and the limit
      // badge looked missing.
      await pushOverlayLayout(picked.layout, scale: picked.scale);
    }
  }

  String _layoutLabel(String id) {
    final mapped = switch (id) {
      'horizontal' || 'pill' => 'horizontal',
      _ => 'vertical',
    };
    for (final l in kOverlayLayouts) {
      if (l.id == mapped) {
        return '${l.label} (${(_overlayScale * 100).round()}%)';
      }
    }
    return 'Nằm dọc (${(_overlayScale * 100).round()}%)';
  }

  void _setPipAspect(String v) {
    if (pipAspect == v) return;
    setState(() {
      pipAspect = v;
      _pipAspect = v;
    });
    unawaited(saveSettings(_currentSettings()));
  }

  Future<void> _toggleBleAutoConnect(bool v) async {
    setState(() {
      _bleAutoConnect = v;
      bleAutoConnect = v;
    });
    await saveSettings(_currentSettings());
  }

  Future<void> _clearRememberedBleDevice() async {
    setState(() {
      _lastBleMac = '';
      _lastBleName = '';
      _lastBleType = 'auto';
      lastBleMac = '';
      lastBleName = '';
      lastBleType = 'auto';
    });
    await saveSettings(_currentSettings());
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
          _buildBluetoothSection(),
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
                    subtitle: 'Nhanh + giao thông',
                    icon: Icons.traffic,
                    selected: dataSource == 'vietmap',
                    onTap: () => _setDataSource('vietmap'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SourceChoice(
                    label: 'Google',
                    subtitle: 'Chuẩn, cần mạng',
                    icon: Icons.place,
                    selected: dataSource == 'google',
                    onTap: () => _setDataSource('google'),
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
                  'Tìm kiếm địa điểm',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  // Taller cells (2.5 overflowed the _SourceChoice card on the
                  // itel's narrow screen — RenderFlex overflow at the bottom).
                  childAspectRatio: 1.6,
                  children: [
                    _SourceChoice(
                      label: 'Google Maps',
                      subtitle: 'Chuẩn, cần khóa API',
                      icon: Icons.place,
                      selected: _geocodingProvider == 'google',
                      onTap: () => _setGeocodingProvider('google'),
                    ),
                    _SourceChoice(
                      label: 'Vietmap',
                      subtitle: 'VN, cần khóa API',
                      icon: Icons.map,
                      selected: _geocodingProvider == 'vietmap',
                      onTap: () => _setGeocodingProvider('vietmap'),
                    ),
                    _SourceChoice(
                      label: 'Photon',
                      subtitle: 'Nhanh, không cần khóa',
                      icon: Icons.bolt,
                      selected: _geocodingProvider == 'photon',
                      onTap: () => _setGeocodingProvider('photon'),
                    ),
                    _SourceChoice(
                      label: 'Nominatim',
                      subtitle: 'OSM chính thức',
                      icon: Icons.public,
                      selected: _geocodingProvider == 'nominatim',
                      onTap: () => _setGeocodingProvider('nominatim'),
                    ),
                  ],
                ),
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
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.record_voice_over,
                    color: kAppBlue,
                    size: 22,
                  ),
                  title: const Text(
                    'Từ khoá đánh thức (wake word)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Nói từ này để gọi trợ lý khi bật "nghe liên tục". '
                    'Mặc định "nav" — đổi nếu máy không nhận.',
                    style: TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    '"${_wakeWordCtrl.text.isEmpty ? wakeWord : _wakeWordCtrl.text}"',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                  onTap: _editWakeWord,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.volume_up, color: kAppBlue, size: 22),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Âm lượng giọng nói',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${(_voiceVolume * 100).round()}%',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                  ],
                ),
                Slider(
                  value: _voiceVolume,
                  onChanged: _setVoiceVolume,
                  activeColor: kAppBlue,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  label: '${(_voiceVolume * 100).round()}%',
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
                        ? 'Chặn fix GPS bất thường (nhảy vị trí / tốc độ ảo) '
                              'trước khi vẽ lên bản đồ.'
                        : 'Dùng GPS thô — không chặn fix nào (vị trí có thể '
                              'nhảy, tốc độ có thể sai).',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
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
                        ? 'Báo bằng giọng nói khi tới gần camera và hiển thị '
                              'chấm camera trên bản đồ.'
                        : 'Tắt cảnh báo + ẩn camera trên bản đồ.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _overlayOn,
                  onChanged: _setOverlay,
                  activeThumbColor: kAppBlue,
                  secondary: const Icon(Icons.speed, color: kAppBlue, size: 22),
                  title: const Text(
                    'Widget nổi tốc độ / giới hạn',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _overlayOn
                        ? 'Cửa sổ nhỏ nổi trên mọi ứng dụng (như Waze Mod): '
                              'tốc độ hiện tại + giới hạn thật + camera gần nhất — '
                              'dùng được khi chạy Google Maps/Waze khác.'
                        : 'Hiện widget tốc độ/giới hạn nổi trên các ứng dụng khác '
                              '(cần quyền "hiển thị trên ứng dụng khác").',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
                // Floating-widget LAYOUT picker (opens a dedicated page).
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(
                    Icons.dashboard_customize,
                    color: kAppBlue,
                    size: 22,
                  ),
                  title: const Text(
                    'Kiểu widget nổi',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _layoutLabel(_overlayLayout),
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: _openOverlayLayout,
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

  /// Bluetooth & external display auto-connect settings.
  Widget _buildBluetoothSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Màn hình ngoài & Bluetooth',
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
                        ? 'Tự động quét & kết nối với đồng hồ E-ink hoặc màn hình NAV-OSM khi mở app hoặc khi ở gần.'
                        : 'Tắt tự động kết nối — bạn cần chọn kết nối thủ công trên bản đồ.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                  ),
                ),
                const Divider(height: 16),
                if (_lastBleMac.isNotEmpty) ...[
                  Row(
                    children: [
                      Icon(
                        _lastBleType == 'map' ? Icons.tv : Icons.watch,
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
                                  : 'Thiết bị BLE',
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
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Chưa lưu thiết bị cụ thể. Khi bật tự động kết nối, app sẽ tự tìm kiếm bất kỳ màn hình E-ink hoặc NAV-OSM nào gần bạn.',
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
