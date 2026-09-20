/// "Nguồn dữ liệu" settings page — pick the map/routing/data provider:
/// OSM (offline-capable), Vietmap (fast VN) or Google. Also SHOWS the routing
/// chain the choice produces (`resolveRouteChain`) and which vehicle behaviour
/// each provider in it can honour, so the toggles stop being a mystery.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/route_profile.dart';
import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/services/offline_tiles.dart' show vehicleType;
import 'package:navbridge/services/route_providers.dart';
import 'package:navbridge/services/vietmap_config.dart' show dataSource;

class DataSourcePage extends StatefulWidget {
  const DataSourcePage({super.key});

  @override
  State<DataSourcePage> createState() => _DataSourcePageState();
}

class _DataSourcePageState extends State<DataSourcePage> {
  Future<void> _setDataSource(String s) async {
    if (dataSource == s) return;
    dataSource = s;
    setState(() {});
    await saveAllSettings();
  }

  /// The profile the nav screen will use, derived from the persisted vehicle
  /// type exactly as `nav_screens.dart` does ('motorbike' → Xe máy, else Ô tô).
  RouteProfile get _profile =>
      vehicleType == 'motorbike' ? RouteProfile.motorbike : RouteProfile.car;

  /// The provider chain the current settings produce (same call the router
  /// makes — see `route_providers.dart`).
  List<RouteProvider> get _chain => resolveRouteChain(_profile);

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Nguồn dữ liệu',
      children: [
        const SettingsSection('Tìm kiếm & chỉ đường'),
        SettingsCard(
          color: const Color(0xFFFEF7E0),
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
                    child: SettingsChoice(
                      label: 'OSM',
                      subtitle: 'Ngoại tuyến được',
                      icon: Icons.public,
                      selected: dataSource == 'osm',
                      onTap: () => _setDataSource('osm'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
                      label: 'Vietmap',
                      subtitle: 'Nhanh + giao thông',
                      icon: Icons.traffic,
                      selected: dataSource == 'vietmap',
                      onTap: () => _setDataSource('vietmap'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
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
        const SettingsSection('Thứ tự dùng khi chỉ đường'),
        SettingsCard(
          color: const Color(0xFFE8F0FE),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nguồn cho ${_profile.label.toLowerCase()} — theo thứ tự. '
                'Nguồn lỗi hoặc không có tuyến thì tự nhảy sang nguồn kế tiếp.',
                style: const TextStyle(fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 10),
              if (_chain.isEmpty)
                const Text(
                  'Không có nguồn nào cho loại xe này với cài đặt hiện tại.',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                )
              else
                for (var i = 0; i < _chain.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _ChainRow(
                    index: i + 1,
                    provider: _chain[i],
                    profile: _profile,
                  ),
                ],
              const SizedBox(height: 10),
              const Text(
                'Vietmap route v4 không có tham số tránh đường — nút "tránh '
                'cao tốc/phà" bị bỏ qua khi nguồn là Vietmap.',
                style: TextStyle(fontSize: 11, height: 1.3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One line of the provider chain: what runs, when, and what it honours.
class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.index,
    required this.provider,
    required this.profile,
  });

  final int index;
  final RouteProvider provider;
  final RouteProfile profile;

  @override
  Widget build(BuildContext context) {
    final mode = switch (provider) {
      RouteProvider.graphhopper => 'ngoại tuyến',
      _ => 'trực tuyến',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$index.',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${provider.label} — $mode',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Tránh cao tốc: '
                '${provider.canAvoidHighway(profile) ? 'có' : 'KHÔNG'} · '
                'Tránh phà: '
                '${provider.canAvoidFerry(profile) ? 'có' : 'KHÔNG'}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
