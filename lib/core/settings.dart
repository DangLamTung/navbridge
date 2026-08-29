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

  /// GPS outlier filter (innovation gate): reject fixes that are too
  /// inaccurate or jump inconsistently with recent speed before they reach
  /// the map / complementary filter / speed chip. Off → raw fixes pass
  /// through unfiltered (position/speed may jump).
  final bool gpsFilter;

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

  /// Floating speed/limit widget layout id: 'vertical' (default) | 'horizontal'.
  /// Picked on the widget-layout page in Settings.
  final String overlayLayout;

  /// Floating widget scale (0.8 to 1.5, default 1.0).
  final double overlayScale;

  /// Spoken guidance volume (0.0–1.0, default 1.0). Applied to the TTS engine
  /// at init and before every utterance.
  final double voiceVolume;

  /// Bluetooth auto-connect: automatically scan & reconnect to external display
  /// (E-ink clock / ESP display) when in range or app launches.
  final bool bleAutoConnect;

  /// Remembered MAC address of the last connected BLE display.
  final String lastBleMac;

  /// Remembered display name (e.g. 'EINK-CLOCK' / 'NAV-OSM').
  final String lastBleName;

  /// Remembered BLE device type: 'clock' | 'map' | 'auto'.
  final String lastBleType;

  const AppSettings({
    this.forceOffline = false,
    this.dataSource = 'osm',
    this.vehicleType = 'car',
    this.geocodingProvider = 'google',
    this.routingEngine = 'auto',
    this.smoothCamera = true,
    this.cameraAlerts = true,
    this.gpsFilter = true,
    this.radar = false,
    this.pipAspect = '34',
    this.ridingMode = false,
    this.simpleMode = false,
    this.wakeWord = 'dậy đi',
    this.overlayLayout = 'vertical',
    this.overlayScale = 1.0,
    this.voiceVolume = 1.0,
    this.bleAutoConnect = true,
    this.lastBleMac = '',
    this.lastBleName = '',
    this.lastBleType = 'auto',
  });

  Map<String, dynamic> toJson() => {
    'forceOffline': forceOffline,
    'dataSource': dataSource,
    'vehicleType': vehicleType,
    'geocodingProvider': geocodingProvider,
    'routingEngine': routingEngine,
    'smoothCamera': smoothCamera,
    'cameraAlerts': cameraAlerts,
    'gpsFilter': gpsFilter,
    'radar': radar,
    'pipAspect': pipAspect,
    'ridingMode': ridingMode,
    'simpleMode': simpleMode,
    'wakeWord': wakeWord,
    'overlayLayout': overlayLayout,
    'overlayScale': overlayScale,
    'voiceVolume': voiceVolume,
    'bleAutoConnect': bleAutoConnect,
    'lastBleMac': lastBleMac,
    'lastBleName': lastBleName,
    'lastBleType': lastBleType,
  };
}

/// Global BLE auto-connect preference + remembered target device.
bool bleAutoConnect = true;
String lastBleMac = '';
String lastBleName = '';
String lastBleType = 'auto';

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
    final rawLayout = (j['overlayLayout'] ?? 'vertical') as String;
    // Map legacy layout names to vertical / horizontal.
    final mappedLayout = switch (rawLayout) {
      'pill' || 'horizontal' => 'horizontal',
      _ => 'vertical',
    };
    final autoConnect = (j['bleAutoConnect'] ?? true) as bool;
    final mac = (j['lastBleMac'] ?? '') as String;
    final name = (j['lastBleName'] ?? '') as String;
    final type = (j['lastBleType'] ?? 'auto') as String;

    bleAutoConnect = autoConnect;
    lastBleMac = mac;
    lastBleName = name;
    lastBleType = type;

    return AppSettings(
      forceOffline: (j['forceOffline'] ?? false) as bool,
      dataSource: (j['dataSource'] ?? 'osm') as String,
      vehicleType: (j['vehicleType'] ?? 'car') as String,
      geocodingProvider: (j['geocodingProvider'] ?? 'photon') as String,
      routingEngine: (j['routingEngine'] ?? 'auto') as String,
      smoothCamera: (j['smoothCamera'] ?? true) as bool,
      cameraAlerts: (j['cameraAlerts'] ?? true) as bool,
      gpsFilter: (j['gpsFilter'] ?? true) as bool,
      radar: (j['radar'] ?? false) as bool,
      pipAspect: (rawPip == 'portrait' || rawPip == 'landscape')
          ? '34'
          : rawPip,
      ridingMode: (j['ridingMode'] ?? false) as bool,
      simpleMode: (j['simpleMode'] ?? false) as bool,
      wakeWord: (j['wakeWord'] ?? 'dậy đi') as String,
      overlayLayout: mappedLayout,
      overlayScale: ((j['overlayScale'] ?? 1.0) as num).toDouble().clamp(
        0.8,
        1.5,
      ),
      voiceVolume: ((j['voiceVolume'] ?? 1.0) as num).toDouble().clamp(
        0.0,
        1.0,
      ),
      bleAutoConnect: autoConnect,
      lastBleMac: mac,
      lastBleName: name,
      lastBleType: type,
    );
  } catch (_) {
    return const AppSettings();
  }
}

Future<void> saveSettings(AppSettings s) async {
  try {
    bleAutoConnect = s.bleAutoConnect;
    lastBleMac = s.lastBleMac;
    lastBleName = s.lastBleName;
    lastBleType = s.lastBleType;
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode(s.toJson()), flush: true);
  } catch (_) {}
}
