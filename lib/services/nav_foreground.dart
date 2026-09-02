/// Background navigation support — Google-Maps style.
///
/// Part A: [FlutterForegroundTask] keeps the app process at foreground
/// priority while navigating, so GPS / the nav engine / BLE writes to the ESP
/// / voice keep running when the app is backgrounded or the screen is off.
/// A persistent notification shows the current maneuver + ETA and updates
/// live (throttled) as the car moves.
///
/// Part B: [FlutterLocalNotificationsPlugin] posts a heads-up banner at each
/// *new* maneuver ("only notify when needed"), separate from the always-on
/// status notification.
///
/// The background [NavTaskHandler] re-emits the last nav state on repeat so
/// the notification stays fresh even if the UI isolate is trimmed; the UI
/// keeps pushing live updates via [updateNav].
library;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide NotificationVisibility;

import 'package:navbridge/core/nav_protocol.dart';
import 'package:navbridge/services/nav_engine.dart';
import 'package:navbridge/services/offline_cameras.dart';

/// Persistent foreground-service notification id.
const int kNavServiceNotificationId = 101;

/// Heads-up maneuver notification base id (each maneuver gets a unique id so
/// consecutive turns stack).
const int kNavManeuverNotificationBase = 200;

/// Heads-up camera alert notification id (reused — only one at a time).
const int kNavCameraNotificationBase = 300;

/// Human label for a camera/point data source (shown in the alert so the
/// driver knows how much to trust it). Matches the map source-ring colours.
String cameraSourceLabel(String source) => switch (source) {
  'waze' => 'Waze',
  'police' => 'CSGT',
  'osm' => 'OSM',
  'vietmap' => 'Vietmap',
  _ => 'Không rõ',
};

/// Global navigator key so a notification tap (foreground-service task or a
/// heads-up maneuver/camera banner) can pop any pushed screen (e.g. the
/// OfflineScreen settings hub) and reopen the navigation page.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Long-running background task: keeps the service alive and refreshes the
/// notification from the last state the UI pushed. Uses [FlutterForegroundTask]
/// shared data (isolate-safe), so the UI isolate and the background isolate
/// agree on the current nav text without touching the engine.
class NavTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Re-push the last known maneuver text (set by the UI via sendDataToTask).
    _refreshFromSharedData();
  }

  @override
  void onNotificationPressed() {
    // The notification was tapped → ask the UI isolate to reopen the
    // navigation page (the OS already brought the app to the foreground).
    FlutterForegroundTask.sendDataToMain(const {'action': 'reopen_nav'});
  }

  Future<void> _refreshFromSharedData() async {
    final String? title = await FlutterForegroundTask.getData<String>(
      key: 'navTitle',
    );
    final String? text = await FlutterForegroundTask.getData<String>(
      key: 'navText',
    );
    if (title != null || text != null) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title ?? 'NavBridge',
        notificationText: text ?? '',
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Facade the UI calls to start/update/stop the background nav.
class NavForegroundService {
  NavForegroundService._();
  static final NavForegroundService instance = NavForegroundService._();

  final FlutterLocalNotificationsPlugin _lnp =
      FlutterLocalNotificationsPlugin();
  bool _lnpReady = false;
  String _lastManeuverSig = ''; // dedupe heads-up banners

  /// Call once at app start (main()).
  Future<void> init() async {
    // Part A: foreground task options.
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'navbridge_nav',
        channelName: 'Navigation',
        channelDescription: 'Turn-by-turn while driving',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        allowWakeLock: true,
      ),
    );

    // Part B: local notifications for heads-up maneuvers.
    final initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    try {
      await _lnp.initialize(
        initSettings,
        // Tapping a heads-up maneuver/camera banner also reopens nav.
        onDidReceiveNotificationResponse: (_) => _reopenNavPage(),
      );
      _lnpReady = true;
      // Request POST_NOTIFICATIONS on Android 13+.
      await _lnp
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[navfg] notifications init failed: $e');
    }

    // Foreground-service notification tap → reopen the navigation page
    // (the background task signals the UI via sendDataToMain).
    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data is Map && data['action'] == 'reopen_nav') {
        _reopenNavPage();
      }
    });
  }

  /// Pop any pushed screens (e.g. the offline/settings hub) so the user lands
  /// back on the navigation page after tapping a nav notification.
  void _reopenNavPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigatorKey.currentState;
      if (nav != null) nav.popUntil((r) => r.isFirst);
    });
  }

  /// Start the persistent service (call when navigation begins).
  Future<void> start() async {
    await FlutterForegroundTask.startService(
      notificationTitle: 'NavBridge',
      notificationText: 'Starting navigation…',
      callback: startCallback,
    );
  }

  /// Keep the process + mic alive for BACKGROUND always-on wake-word
  /// listening. The STT loop runs in the main isolate; a foreground service
  /// stops Android from killing the process (or revoking mic access) while
  /// the screen is off / the app is backgrounded. If navigation already
  /// started the service we leave it as-is (nav keeps the process alive too).
  Future<void> startVoiceService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'NavBridge — đang nghe lệnh thoại',
      notificationText: 'Nói "NavBridge" để ra lệnh',
      callback: startCallback,
    );
  }

  /// Stop the foreground service — call ONLY when navigation is not active
  /// (nav relies on the same service to keep running in the background).
  Future<void> stopVoiceService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Push a live nav update to the notification. Throttled to ~5 s so a busy
  /// phone isn't rebuilding the platform notification + channel call on EVERY
  /// GPS fix (1-2 Hz) — that per-fix platform work added up on low-end
  /// devices and contributed to the long-route "not responding" CPU. The
  /// notification showing a distance up to 5 s old is unnoticeable.
  DateTime? _lastNavUpdate;
  Future<void> updateNav(NavProgress? nav, {String eta = ''}) async {
    if (nav == null) return;
    final now = DateTime.now();
    if (_lastNavUpdate != null &&
        now.difference(_lastNavUpdate!) < const Duration(seconds: 5)) {
      return;
    }
    _lastNavUpdate = now;
    final icon = '${iconSymbol(nav.iconCode)} ';
    final title = '$icon$eta';
    final text =
        '${nav.text.isNotEmpty ? nav.text : 'Next maneuver'} — '
        '${nav.meter}m';
    FlutterForegroundTask.sendDataToTask({'navTitle': title, 'navText': text});
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Post a heads-up banner when a NEW maneuver fires. Deduped by
  /// maneuver signature (icon + road), like the spoken guidance.
  Future<void> notifyManeuver(NavProgress nav) async {
    if (!_lnpReady) return;
    final sig = '${nav.iconCode}|${nav.text}';
    if (sig == _lastManeuverSig) return;
    _lastManeuverSig = sig;

    final icon = '${iconSymbol(nav.iconCode)} ';
    final title = '$icon${nav.text.isNotEmpty ? nav.text : 'Next maneuver'}';
    final body =
        'in ${nav.meter}m · ETA ${_fmt(nav.etaHour)}:${_fmt(nav.etaMinute)}';

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'navbridge_maneuvers',
        'Turn alerts',
        channelDescription: 'Heads-up at each turn',
        importance: Importance.max,
        priority: Priority.high,
      ),
    );
    try {
      await _lnp.show(
        kNavManeuverNotificationBase + nav.iconCode,
        title,
        body,
        details,
      );
    } catch (e) {
      debugPrint('[navfg] maneuver notify failed: $e');
    }
  }

  /// Post a heads-up banner for a speed/red-light camera ahead (phạt nguội
  /// DB). Uses a high-priority channel so it's visible even with the screen
  /// off / app backgrounded — the driver just needs the warning. The body now
  /// names the DATA SOURCE (Waze / Vietmap / CSGT / OSM) so the driver knows
  /// how much to trust the alert.
  Future<void> notifyCamera(OfflineCamera cam, int metersAhead) async {
    if (!_lnpReady) return;
    final emoji = switch (cam.focus) {
      'speed' => '📷',
      'red_light' => '🚦',
      _ => '📸',
    };
    final label = switch (cam.focus) {
      'speed' => 'Camera tốc độ',
      'red_light' => 'Camera đèn đỏ',
      _ => 'Camera',
    };
    final title = '$emoji $label phía trước ${metersAhead}m';
    final body = '${cam.name}\n· Nguồn: ${cameraSourceLabel(cam.source)}';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'navbridge_cameras',
        'Camera alerts',
        channelDescription: 'Speed / red-light camera ahead',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      ),
    );
    try {
      await _lnp.show(kNavCameraNotificationBase, title, body, details);
    } catch (e) {
      debugPrint('[navfg] camera notify failed: $e');
    }
  }

  /// Post a high-priority alert for a vehicle prohibition (e.g. xe mô tô
  /// không được vào cao tốc). Seen even with the screen off.
  Future<void> notifyProhibition(String title, String body) async {
    if (!_lnpReady) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'navbridge_prohibitions',
        'Prohibition alerts',
        channelDescription: 'Vehicle not permitted on this road',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      ),
    );
    try {
      await _lnp.show(kNavCameraNotificationBase + 1, title, body, details);
    } catch (e) {
      debugPrint('[navfg] prohibition notify failed: $e');
    }
  }

  /// Heads-up that a LONG fuel gap is ahead — tell the driver to prepare
  /// (refuel soon). Seen with the screen off.
  Future<void> notifyFuelWarning(String title, String body) async {
    if (!_lnpReady) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'navbridge_fuel',
        'Fuel alerts',
        channelDescription: 'Long stretch with no gas station ahead',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      ),
    );
    try {
      await _lnp.show(kNavCameraNotificationBase + 2, title, body, details);
    } catch (e) {
      debugPrint('[navfg] fuel notify failed: $e');
    }
  }

  /// Stop the service + clear banners (call when navigation ends).
  Future<void> stop() async {
    _lastManeuverSig = '';
    if (_lnpReady) {
      try {
        await _lnp.cancelAll();
      } catch (_) {}
    }
    await FlutterForegroundTask.stopService();
  }

  static String _fmt(int v) => v < 10 ? '0$v' : '$v';
}

/// Background isolate entry point (required by flutter_foreground_task).
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(NavTaskHandler());
}
