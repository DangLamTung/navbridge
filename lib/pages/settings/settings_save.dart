/// Shared helper that snapshots ALL current settings globals into a persisted
/// [AppSettings] and saves it. Every grouped settings page calls this after an
/// edit so editing one preference never drops the others.
library;

import 'package:navbridge/core/settings.dart';
import 'package:navbridge/services/offline_tiles.dart'
    show
        forceOffline,
        vehicleType,
        geocodingProvider,
        routingEngine,
        smoothCamera,
        cameraAlerts,
        gpsFilter,
        radarOn,
        pipAspect,
        ridingMode,
        voiceVolume,
        wakeWord,
        simpleMode,
        navSpeedStyle;
import 'package:navbridge/services/overlay_visibility.dart'
    show overlayEnabled, overlayLayout, overlayScale;
import 'package:navbridge/services/vietmap_config.dart' show dataSource;

/// Build an [AppSettings] from the current in-memory globals.
AppSettings snapshotSettings() => AppSettings(
  forceOffline: forceOffline,
  dataSource: dataSource,
  vehicleType: vehicleType,
  geocodingProvider: geocodingProvider,
  routingEngine: routingEngine,
  smoothCamera: smoothCamera,
  cameraAlerts: cameraAlerts,
  gpsFilter: gpsFilter,
  navSpeedStyle: navSpeedStyle,
  radar: radarOn,
  pipAspect: pipAspect,
  ridingMode: ridingMode,
  voiceVolume: voiceVolume,
  voiceBoostMax: voiceBoostMax,
  ttsVoiceName: ttsVoiceName,
  ttsVoiceLocale: ttsVoiceLocale,
  voicePack: voicePack,
  simpleMode: simpleMode,
  wakeWord: wakeWord,
  overlayLayout: overlayLayout,
  overlayScale: overlayScale,
  overlayEnabled: overlayEnabled,
  bleAutoConnect: bleAutoConnect,
  lastBleMac: lastBleMac,
  lastBleName: lastBleName,
  lastBleType: lastBleType,
  gpsFilterStrength: gpsFilterStrength,
  aiCustomPrompt: aiCustomPrompt,
  aiPlaceSuggestions: aiPlaceSuggestions,
  ttsSpeechRate: ttsSpeechRate,
  ttsPitch: ttsPitch,
  aiProvider: aiProvider,
  aiDeepSeekBaseUrl: aiDeepSeekBaseUrl,
  aiDeepSeekModel: aiDeepSeekModel,
  aiWebSearch: aiWebSearch,
);

/// Persist every current settings global to disk.
Future<void> saveAllSettings() async {
  // Never let a save snapshot defaults before the async startup load has
  // applied the persisted values to the globals (would clobber the user's
  // settings on disk).
  await ensureSettingsLoaded();
  await saveSettings(snapshotSettings());
}
