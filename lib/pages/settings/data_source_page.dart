/// "Nguồn dữ liệu" settings page — pick the map/routing/data provider:
/// OSM (offline-capable), Vietmap (fast VN) or Google.
library;

import 'package:flutter/material.dart';

import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
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
      ],
    );
  }
}
