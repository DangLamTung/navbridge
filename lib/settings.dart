/// Tiny persisted app settings (currently just the offline/online mode).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  final bool forceOffline;

  const AppSettings({this.forceOffline = false});

  Map<String, dynamic> toJson() => {'forceOffline': forceOffline};
}

Future<File> _settingsFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/settings.json');
}

Future<AppSettings> loadSettings() async {
  try {
    final f = await _settingsFile();
    if (!f.existsSync()) return const AppSettings();
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return AppSettings(forceOffline: (j['forceOffline'] ?? false) as bool);
  } catch (_) {
    return const AppSettings();
  }
}

Future<void> saveSettings(AppSettings s) async {
  try {
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode(s.toJson()), flush: true);
  } catch (_) {}
}
