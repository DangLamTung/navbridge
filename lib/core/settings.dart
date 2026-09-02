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

  /// Cap on the Android media-stream volume the app pushes during an
  /// announcement's loudness boost (0.0–1.0, default 0.7). The boost raises
  /// the media stream to at least this fraction of its max so the nav voice is
  /// audible over engine/wind noise — but never above it (or the user's own
  /// volume) so it doesn't blast.
  final double voiceBoostMax;

  /// Selected TextToSpeech voice name (empty = engine default). Picked on the
  /// settings "Giọng đọc" picker from the platform's installed voices.
  final String ttsVoiceName;

  /// BCP-47 locale for [(ttsVoiceName)] (e.g. 'vi-VN').
  final String ttsVoiceLocale;

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
    this.voiceBoostMax = 0.7,
    this.ttsVoiceName = '',
    this.ttsVoiceLocale = 'vi-VN',
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
    'voiceBoostMax': voiceBoostMax,
    'ttsVoiceName': ttsVoiceName,
    'ttsVoiceLocale': ttsVoiceLocale,
    'bleAutoConnect': bleAutoConnect,
    'lastBleMac': lastBleMac,
    'lastBleName': lastBleName,
    'lastBleType': lastBleType,
  };

  AppSettings copyWith({
    bool? forceOffline,
    String? dataSource,
    String? vehicleType,
    String? geocodingProvider,
    String? routingEngine,
    bool? smoothCamera,
    bool? cameraAlerts,
    bool? gpsFilter,
    bool? radar,
    String? pipAspect,
    bool? ridingMode,
    bool? simpleMode,
    String? wakeWord,
    String? overlayLayout,
    double? overlayScale,
    double? voiceVolume,
    double? voiceBoostMax,
    String? ttsVoiceName,
    String? ttsVoiceLocale,
    bool? bleAutoConnect,
    String? lastBleMac,
    String? lastBleName,
    String? lastBleType,
  }) {
    return AppSettings(
      forceOffline: forceOffline ?? this.forceOffline,
      dataSource: dataSource ?? this.dataSource,
      vehicleType: vehicleType ?? this.vehicleType,
      geocodingProvider: geocodingProvider ?? this.geocodingProvider,
      routingEngine: routingEngine ?? this.routingEngine,
      smoothCamera: smoothCamera ?? this.smoothCamera,
      cameraAlerts: cameraAlerts ?? this.cameraAlerts,
      gpsFilter: gpsFilter ?? this.gpsFilter,
      radar: radar ?? this.radar,
      pipAspect: pipAspect ?? this.pipAspect,
      ridingMode: ridingMode ?? this.ridingMode,
      simpleMode: simpleMode ?? this.simpleMode,
      wakeWord: wakeWord ?? this.wakeWord,
      overlayLayout: overlayLayout ?? this.overlayLayout,
      overlayScale: overlayScale ?? this.overlayScale,
      voiceVolume: voiceVolume ?? this.voiceVolume,
      voiceBoostMax: voiceBoostMax ?? this.voiceBoostMax,
      ttsVoiceName: ttsVoiceName ?? this.ttsVoiceName,
      ttsVoiceLocale: ttsVoiceLocale ?? this.ttsVoiceLocale,
      bleAutoConnect: bleAutoConnect ?? this.bleAutoConnect,
      lastBleMac: lastBleMac ?? this.lastBleMac,
      lastBleName: lastBleName ?? this.lastBleName,
      lastBleType: lastBleType ?? this.lastBleType,
    );
  }
}

/// Global BLE auto-connect preference + remembered target device.
bool bleAutoConnect = true;
String lastBleMac = '';
String lastBleName = '';
String lastBleType = 'auto';

/// Selected TextToSpeech voice (from the platform TTS voice list). Empty =
/// the engine default. `ttsVoiceLocale` is the BCP-47 locale of the voice.
String ttsVoiceName = '';
String ttsVoiceLocale = 'vi-VN';

/// Cap on the media-stream volume pushed during an announcement's loudness
/// boost (see [voiceBoostMax] on [AppSettings]).
double voiceBoostMax = 0.7;

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
    // Map legacy layout names to vertical / horizontal / dial.
    final mappedLayout = switch (rawLayout) {
      'dial' || 'speedometer' => 'dial',
      'pill' || 'horizontal' => 'horizontal',
      _ => 'vertical',
    };
    final autoConnect = (j['bleAutoConnect'] ?? true) as bool;
    final mac = (j['lastBleMac'] ?? '') as String;
    final name = (j['lastBleName'] ?? '') as String;
    final type = (j['lastBleType'] ?? 'auto') as String;
    final voiceName = (j['ttsVoiceName'] ?? '') as String;
    final voiceLocale = (j['ttsVoiceLocale'] ?? 'vi-VN') as String;
    final boostMax = ((j['voiceBoostMax'] ?? 0.7) as num).toDouble().clamp(
      0.0,
      1.0,
    );

    bleAutoConnect = autoConnect;
    lastBleMac = mac;
    lastBleName = name;
    lastBleType = type;
    ttsVoiceName = voiceName;
    ttsVoiceLocale = voiceLocale;
    voiceBoostMax = boostMax;

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
      voiceBoostMax: boostMax,
      ttsVoiceName: voiceName,
      ttsVoiceLocale: voiceLocale,
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
    ttsVoiceName = s.ttsVoiceName;
    ttsVoiceLocale = s.ttsVoiceLocale;
    voiceBoostMax = s.voiceBoostMax;
    bleAutoConnect = s.bleAutoConnect;
    lastBleMac = s.lastBleMac;
    lastBleName = s.lastBleName;
    lastBleType = s.lastBleType;
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode(s.toJson()), flush: true);
  } catch (_) {}
}
