/// "Bong bóng nổi" settings page — the floating speed/limit widget and the
/// picture-in-picture window shape while navigating.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/services/offline_tiles.dart' show pipAspect;
import 'package:navbridge/services/overlay_visibility.dart'
    show overlayEnabled, overlayLayout, overlayScale;
import 'package:navbridge/services/overlay_widget.dart';
import 'package:navbridge/ui/overlay_layout_screen.dart';
import 'package:navbridge/ui/widgets.dart';

class OverlaySettingsPage extends StatefulWidget {
  const OverlaySettingsPage({super.key});

  @override
  State<OverlaySettingsPage> createState() => _OverlaySettingsPageState();
}

class _OverlaySettingsPageState extends State<OverlaySettingsPage> {
  bool _overlayOn = false;
  String _overlayLayout = 'vertical';
  double _overlayScale = 1.0;
  String _pipAspect = '34';

  @override
  void initState() {
    super.initState();
    _overlayOn = overlayEnabled;
    _overlayLayout = overlayLayout;
    _overlayScale = overlayScale;
    _pipAspect = pipAspect;
  }

  /// Floating speed-limit / camera widget over other apps (Waze-Mod style):
  /// requests the "display over other apps" permission and shows/hides the
  /// self-contained overlay widget. Persists [overlayEnabled] so it's
  /// auto-shown the next time the app starts.
  Future<void> _setOverlay(bool v) async {
    if (v) {
      await startOverlay();
      if (!mounted) return;
      final granted = await overlayPermissionGranted();
      overlayEnabled = granted;
      await saveAllSettings();
      if (mounted) setState(() => _overlayOn = granted);
    } else {
      await stopOverlay();
      overlayEnabled = false;
      await saveAllSettings();
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
      await saveAllSettings();
      // Push the new layout + scale to the RUNNING overlay and resize its
      // window NOW, so the bubble doesn't keep the old layout/window size.
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
    unawaited(saveAllSettings());
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Bong bóng nổi',
      children: [
        const SettingsSection('Widget nổi'),
        SettingsCard(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _overlayOn,
                onChanged: _setOverlay,
                activeThumbColor: kAppBlue,
                secondary: const Icon(
                  Icons.speed,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Widget nổi tốc độ / giới hạn',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _overlayOn
                      ? 'Cửa sổ nhỏ nổi trên mọi ứng dụng (như Waze Mod): '
                            'tốc độ hiện tại + giới hạn thật + camera gần nhất — '
                            'dùng được khi chạy Google Maps/Waze khác.'
                      : 'Hiện widget tốc độ/giới hạn nổi trên các ứng dụng khác '
                            '(cần quyền "hiển thị trên ứng dụng khác").',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
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
            ],
          ),
        ),
        const SizedBox(height: 14),

        const SettingsSection('Hướng cửa sổ nổi (PiP)'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final a in const ['34', 'portrait', 'landscape']) ...[
                    Expanded(
                      child: SettingsChoice(
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
                'Hướng cửa sổ nổi khi dẫn đường (đổi ngay cả khi cửa sổ đang '
                'mở).',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
