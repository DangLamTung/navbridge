/// Tiny persisted app settings (currently just the offline/online mode).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  final bool forceOffline;

  /// Map/routing data source: 'osm' (default) | 'vietmap'.
  final String dataSource;

  /// Vehicle used for speed-limit defaults: 'car' | 'motorbike' | 'truck'.
  final String vehicleType;

  /// Online geocoding provider: 'photon' (Komoot, default) | 'nominatim' |
  /// 'vietmap' (Vietnamese-focused search — needs Vietmap API keys).
  final String geocodingProvider;

  /// Routing engine for car routes: 'auto' | 'graphhopper' | 'osrm'.
  final String routingEngine;

  /// Google-style smooth map movement (continuous camera easing + dead-
  /// reckoning between 1 Hz GPS fixes rendered at display rate).
  final bool smoothCamera;

  /// Speed/red-light camera alerts while navigating (phạt nguội DB).
  final bool cameraAlerts;

  /// Rain-radar overlay on the map (RainViewer, free/no key).
  final bool radar;

  /// Picture-in-Picture window shape while navigating:
  ///   '34' 3:4 (default — larger, easy to read)
  ///   'portrait' 9:16 · 'landscape' 4:3
  final String pipAspect;

  /// Riding mode: tune speech recognition for a moving motorbike — prefer
  /// the Bluetooth headset mic, use the short-command (search) recognizer
  /// model, and wait longer through wind bursts so commands aren't cut off.
  final bool ridingMode;

  /// Simple nav mode: while navigating, hide the map and show only a big
  /// maneuver arrow + distance/ETA + voice commands (cleaner, lighter).
  final bool simpleMode;

  /// Wake word for the always-on voice assistant (default "nav"). Made
  /// configurable because cheap phones' recognizers transcribe it
  /// differently — the user sets whatever word their device actually hears.
  final String wakeWord;

  const AppSettings({
    this.forceOffline = false,
    this.dataSource = 'osm',
    this.vehicleType = 'car',
    this.geocodingProvider = 'photon',
    this.routingEngine = 'auto',
    this.smoothCamera = true,
    this.cameraAlerts = true,
    this.radar = false,
    this.pipAspect = '34',
    this.ridingMode = false,
    this.simpleMode = false,
    this.wakeWord = 'dậy đi',
  });

  Map<String, dynamic> toJson() => {
    'forceOffline': forceOffline,
    'dataSource': dataSource,
    'vehicleType': vehicleType,
    'geocodingProvider': geocodingProvider,
    'routingEngine': routingEngine,
    'smoothCamera': smoothCamera,
    'cameraAlerts': cameraAlerts,
    'radar': radar,
    'pipAspect': pipAspect,
    'ridingMode': ridingMode,
    'simpleMode': simpleMode,
    'wakeWord': wakeWord,
  };
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
    // The user asked for the larger 3:4 PiP — migrate any older value so it
    // takes effect on existing installs instead of silently keeping 9:16/4:3.
    final rawPip = (j['pipAspect'] ?? '34') as String;
    return AppSettings(
      forceOffline: (j['forceOffline'] ?? false) as bool,
      dataSource: (j['dataSource'] ?? 'osm') as String,
      vehicleType: (j['vehicleType'] ?? 'car') as String,
      geocodingProvider: (j['geocodingProvider'] ?? 'photon') as String,
      routingEngine: (j['routingEngine'] ?? 'auto') as String,
      smoothCamera: (j['smoothCamera'] ?? true) as bool,
      cameraAlerts: (j['cameraAlerts'] ?? true) as bool,
      radar: (j['radar'] ?? false) as bool,
      pipAspect: (rawPip == 'portrait' || rawPip == 'landscape')
          ? '34'
          : rawPip,
      ridingMode: (j['ridingMode'] ?? false) as bool,
      simpleMode: (j['simpleMode'] ?? false) as bool,
      wakeWord: (j['wakeWord'] ?? 'dậy đi') as String,
    );
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
