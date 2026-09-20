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

  /// Whether the floating speed/limit widget is enabled (shown) at all.
  /// Persisted so it survives app background/restart and can be auto-shown on
  /// launch. The widget runs in its own engine, so it keeps working over other
  /// apps even when NavBridge is backgrounded.
  final bool overlayEnabled;

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

  /// Which pre-recorded voice pack to use for the speed-limit / alert
  /// announcements. Empty = system TTS only (no pre-recorded clips). When set
  /// it must match a folder under `assets/audio/<pack>/` (e.g.
  /// 'voice_vn_fast'). Picked on the "Giọng nói" page.
  final String voicePack;

  /// Bluetooth auto-connect: automatically scan & reconnect to external display
  /// (E-ink clock / ESP display) when in range or app launches.
  final bool bleAutoConnect;

  /// Remembered MAC address of the last connected BLE display.
  final String lastBleMac;

  /// Remembered display name (e.g. 'EINK-CLOCK' / 'NAV-OSM').
  final String lastBleName;

  /// Remembered BLE device type: 'clock' | 'map' | 'auto'.
  final String lastBleType;

  /// GPS outlier-filter strength: 'light' | 'standard' | 'strong'. Tunes how
  /// aggressively bad fixes are rejected (accuracy / jump thresholds).
  final String gpsFilterStrength;

  /// Custom AI system-prompt instructions appended to the assistant's base
  /// prompt (driver preferences, style, …) — editable in the AI settings.
  final String aiCustomPrompt;

  /// Show one-tap, location-aware suggested questions in the AI chat panel.
  final bool aiPlaceSuggestions;

  /// Spoken guidance speech rate (0.0–1.0, default 0.55).
  final double ttsSpeechRate;

  /// Spoken guidance voice pitch (0.5–2.0, default 1.0).
  final double ttsPitch;

  /// AI provider preference: 'auto' (DeepSeek → Gemini fallback) | 'deepseek'
  /// | 'gemini'.
  final String aiProvider;

  /// Override the DeepSeek / OpenAI-compatible base URL (e.g. a self-hosted
  /// proxy). Empty = default [AiConfig.deepSeekEndpoint].
  final String aiDeepSeekBaseUrl;

  /// Override the DeepSeek model id. Empty = default [AiConfig.deepSeekModel].
  final String aiDeepSeekModel;

  /// AI web-search grounding on/off (real-time facts drawn from the web).
  final bool aiWebSearch;

  /// How the current speed + posted limit are drawn WHILE NAVIGATING:
  ///   'chip' — compact white chip with two small dials (default)
  ///   'dial' — the floating speed widget's round gauge (tick sweep + big
  ///            number) with the limit sign overlapping it.
  final String navSpeedStyle;

  const AppSettings({
    this.forceOffline = false,
    this.dataSource = 'osm',
    this.vehicleType = 'car',
    this.geocodingProvider = 'photon',
    this.routingEngine = 'auto',
    this.smoothCamera = true,
    this.cameraAlerts = true,
    this.gpsFilter = true,
    this.radar = false,
    this.pipAspect = '34',
    this.ridingMode = false,
    this.simpleMode = false,
    this.wakeWord = 'dậy đi',
    this.overlayEnabled = false,
    this.overlayLayout = 'vertical',
    this.overlayScale = 1.0,
    this.voiceVolume = 1.0,
    this.voiceBoostMax = 0.7,
    this.ttsVoiceName = '',
    this.ttsVoiceLocale = 'vi-VN',
    this.voicePack = 'voice_vn_fast',
    this.bleAutoConnect = true,
    this.lastBleMac = '',
    this.lastBleName = '',
    this.lastBleType = 'auto',
    this.gpsFilterStrength = 'standard',
    this.aiCustomPrompt = '',
    this.aiPlaceSuggestions = true,
    this.ttsSpeechRate = 0.55,
    this.ttsPitch = 1.0,
    this.aiProvider = 'auto',
    this.aiDeepSeekBaseUrl = '',
    this.aiDeepSeekModel = '',
    this.aiWebSearch = true,
    this.navSpeedStyle = 'dial',
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
    'navSpeedStyle': navSpeedStyle,
    'radar': radar,
    'pipAspect': pipAspect,
    'ridingMode': ridingMode,
    'simpleMode': simpleMode,
    'wakeWord': wakeWord,
    'overlayLayout': overlayLayout,
    'overlayScale': overlayScale,
    'overlayEnabled': overlayEnabled,
    'voiceVolume': voiceVolume,
    'voiceBoostMax': voiceBoostMax,
    'ttsVoiceName': ttsVoiceName,
    'ttsVoiceLocale': ttsVoiceLocale,
    'voicePack': voicePack,
    'bleAutoConnect': bleAutoConnect,
    'lastBleMac': lastBleMac,
    'lastBleName': lastBleName,
    'lastBleType': lastBleType,
    'gpsFilterStrength': gpsFilterStrength,
    'aiCustomPrompt': aiCustomPrompt,
    'aiPlaceSuggestions': aiPlaceSuggestions,
    'ttsSpeechRate': ttsSpeechRate,
    'ttsPitch': ttsPitch,
    'aiProvider': aiProvider,
    'aiDeepSeekBaseUrl': aiDeepSeekBaseUrl,
    'aiDeepSeekModel': aiDeepSeekModel,
    'aiWebSearch': aiWebSearch,
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
    bool? overlayEnabled,
    double? voiceVolume,
    double? voiceBoostMax,
    String? ttsVoiceName,
    String? ttsVoiceLocale,
    String? voicePack,
    bool? bleAutoConnect,
    String? lastBleMac,
    String? lastBleName,
    String? lastBleType,
    String? gpsFilterStrength,
    String? aiCustomPrompt,
    bool? aiPlaceSuggestions,
    double? ttsSpeechRate,
    double? ttsPitch,
    String? aiProvider,
    String? aiDeepSeekBaseUrl,
    String? aiDeepSeekModel,
    bool? aiWebSearch,
    String? navSpeedStyle,
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
      navSpeedStyle: navSpeedStyle ?? this.navSpeedStyle,
      radar: radar ?? this.radar,
      pipAspect: pipAspect ?? this.pipAspect,
      ridingMode: ridingMode ?? this.ridingMode,
      simpleMode: simpleMode ?? this.simpleMode,
      wakeWord: wakeWord ?? this.wakeWord,
      overlayLayout: overlayLayout ?? this.overlayLayout,
      overlayScale: overlayScale ?? this.overlayScale,
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      voiceVolume: voiceVolume ?? this.voiceVolume,
      voiceBoostMax: voiceBoostMax ?? this.voiceBoostMax,
      ttsVoiceName: ttsVoiceName ?? this.ttsVoiceName,
      ttsVoiceLocale: ttsVoiceLocale ?? this.ttsVoiceLocale,
      voicePack: voicePack ?? this.voicePack,
      bleAutoConnect: bleAutoConnect ?? this.bleAutoConnect,
      lastBleMac: lastBleMac ?? this.lastBleMac,
      lastBleName: lastBleName ?? this.lastBleName,
      lastBleType: lastBleType ?? this.lastBleType,
      gpsFilterStrength: gpsFilterStrength ?? this.gpsFilterStrength,
      aiCustomPrompt: aiCustomPrompt ?? this.aiCustomPrompt,
      aiPlaceSuggestions: aiPlaceSuggestions ?? this.aiPlaceSuggestions,
      ttsSpeechRate: ttsSpeechRate ?? this.ttsSpeechRate,
      ttsPitch: ttsPitch ?? this.ttsPitch,
      aiProvider: aiProvider ?? this.aiProvider,
      aiDeepSeekBaseUrl: aiDeepSeekBaseUrl ?? this.aiDeepSeekBaseUrl,
      aiDeepSeekModel: aiDeepSeekModel ?? this.aiDeepSeekModel,
      aiWebSearch: aiWebSearch ?? this.aiWebSearch,
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

/// Active pre-recorded voice pack (folder under `assets/audio/`). Empty =
/// system TTS only. `SoundAlerts` reads this to pick which clips to play.
///
/// `voice_vn_fast` is the fastest Vietnamese pack (the shortest clip per phrase
/// merged from the Waze mod's four VN packs — see tools/build_voice_pack_vn.py).
/// `voice_thai_ngoc_bich` was the old default and is ~14% slower; settings
/// saved with it are migrated on load.
String voicePack = 'voice_vn_fast';

/// Cap on the media-stream volume pushed during an announcement's loudness
/// boost (see [voiceBoostMax] on [AppSettings]).
double voiceBoostMax = 0.7;

/// GPS outlier-filter strength: 'light' | 'standard' | 'strong'.
String gpsFilterStrength = 'standard';

/// Custom AI system-prompt instructions (appended to the base prompt).
String aiCustomPrompt = '';

/// Show location-aware suggested questions in the AI chat panel.
bool aiPlaceSuggestions = true;

/// Spoken guidance speech rate (0.0–1.0, default 0.55).
double ttsSpeechRate = 0.55;

/// Spoken guidance voice pitch (0.5–2.0, default 1.0).
double ttsPitch = 1.0;

/// AI provider preference: 'auto' | 'deepseek' | 'gemini'.
String aiProvider = 'auto';

/// Override the DeepSeek / OpenAI-compatible base URL (empty = default).
String aiDeepSeekBaseUrl = '';

/// Override the DeepSeek model id (empty = default).
String aiDeepSeekModel = '';

/// AI web-search grounding on/off (real-time facts).
bool aiWebSearch = true;

Future<File> _settingsFile() async {
  final sup = await getApplicationSupportDirectory();
  return File('${sup.path}/settings.json');
}

bool _settingsLoaded = false;
Future<AppSettings>? _loadRunning;

/// Load the persisted settings once, applying them to the in-memory globals.
/// Memoised so concurrent callers share a single load; sets [_settingsLoaded]
/// when a load attempt finishes (success or fallback to defaults).
Future<AppSettings> loadSettings() {
  return _loadRunning ??= _loadSettingsOnce().whenComplete(() {
    _loadRunning = null;
  });
}

/// Ensures the persisted settings have been applied to the globals at least
/// once. Guards a settings save from overwriting saved values with defaults
/// when the user saves before the async startup load finished.
Future<void> ensureSettingsLoaded() async {
  if (_settingsLoaded) return;
  await loadSettings();
}

Future<AppSettings> _loadSettingsOnce() async {
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
    final rawPack = (j['voicePack'] ?? 'voice_vn_fast') as String;
    // Migrate the old default: `voice_thai_ngoc_bich` was the only bundled
    // pack before `voice_vn_fast` existed, so anybody still on it never chose
    // it deliberately — move them to the faster merged pack (14% less speech,
    // and the overspeed warning drops 2.74 s -> 1.63 s).
    final pack = rawPack == 'voice_thai_ngoc_bich' ? 'voice_vn_fast' : rawPack;
    final boostMax = ((j['voiceBoostMax'] ?? 0.7) as num).toDouble().clamp(
      0.0,
      1.0,
    );

    final gpsStrength = (j['gpsFilterStrength'] ?? 'standard') as String;
    final customPrompt = (j['aiCustomPrompt'] ?? '') as String;
    final placeSuggestions = (j['aiPlaceSuggestions'] ?? true) as bool;
    final speechRate = ((j['ttsSpeechRate'] ?? 0.55) as num)
        .toDouble()
        .clamp(0.0, 1.0);
    final pitch = ((j['ttsPitch'] ?? 1.0) as num)
        .toDouble()
        .clamp(0.5, 2.0);
    final aiProv = (j['aiProvider'] ?? 'auto') as String;
    final aiBase = (j['aiDeepSeekBaseUrl'] ?? '') as String;
    final aiModel = (j['aiDeepSeekModel'] ?? '') as String;
    final aiWeb = (j['aiWebSearch'] ?? true) as bool;

    bleAutoConnect = autoConnect;
    lastBleMac = mac;
    lastBleName = name;
    lastBleType = type;
    ttsVoiceName = voiceName;
    ttsVoiceLocale = voiceLocale;
    voicePack = pack;
    voiceBoostMax = boostMax;
    gpsFilterStrength = gpsStrength;
    aiCustomPrompt = customPrompt;
    aiPlaceSuggestions = placeSuggestions;
    ttsSpeechRate = speechRate;
    ttsPitch = pitch;
    aiProvider = aiProv;
    aiDeepSeekBaseUrl = aiBase;
    aiDeepSeekModel = aiModel;
    aiWebSearch = aiWeb;

    return AppSettings(
      forceOffline: (j['forceOffline'] ?? false) as bool,
      dataSource: (j['dataSource'] ?? 'osm') as String,
      vehicleType: (j['vehicleType'] ?? 'car') as String,
      geocodingProvider: (j['geocodingProvider'] ?? 'photon') as String,
      routingEngine: (j['routingEngine'] ?? 'auto') as String,
      smoothCamera: (j['smoothCamera'] ?? true) as bool,
      cameraAlerts: (j['cameraAlerts'] ?? true) as bool,
      gpsFilter: (j['gpsFilter'] ?? true) as bool,
      navSpeedStyle: (j['navSpeedStyle'] ?? 'dial') as String,
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
      overlayEnabled: (j['overlayEnabled'] ?? false) as bool,
      voiceVolume: ((j['voiceVolume'] ?? 1.0) as num).toDouble().clamp(
        0.0,
        1.0,
      ),
      voiceBoostMax: boostMax,
      ttsVoiceName: voiceName,
      ttsVoiceLocale: voiceLocale,
      voicePack: pack,
      bleAutoConnect: autoConnect,
      lastBleMac: mac,
      lastBleName: name,
      lastBleType: type,
      gpsFilterStrength: gpsStrength,
      aiCustomPrompt: customPrompt,
      aiPlaceSuggestions: placeSuggestions,
      ttsSpeechRate: speechRate,
      ttsPitch: pitch,
      aiProvider: aiProv,
      aiDeepSeekBaseUrl: aiBase,
      aiDeepSeekModel: aiModel,
      aiWebSearch: aiWeb,
    );
  } catch (_) {
    return const AppSettings();
  } finally {
    _settingsLoaded = true;
  }
}

Future<void> saveSettings(AppSettings s) async {
  try {
    ttsVoiceName = s.ttsVoiceName;
    ttsVoiceLocale = s.ttsVoiceLocale;
    voicePack = s.voicePack;
    voiceBoostMax = s.voiceBoostMax;
    bleAutoConnect = s.bleAutoConnect;
    lastBleMac = s.lastBleMac;
    lastBleName = s.lastBleName;
    lastBleType = s.lastBleType;
    gpsFilterStrength = s.gpsFilterStrength;
    aiCustomPrompt = s.aiCustomPrompt;
    aiPlaceSuggestions = s.aiPlaceSuggestions;
    ttsSpeechRate = s.ttsSpeechRate;
    ttsPitch = s.ttsPitch;
    aiProvider = s.aiProvider;
    aiDeepSeekBaseUrl = s.aiDeepSeekBaseUrl;
    aiDeepSeekModel = s.aiDeepSeekModel;
    aiWebSearch = s.aiWebSearch;
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode(s.toJson()), flush: true);
  } catch (_) {}
}
