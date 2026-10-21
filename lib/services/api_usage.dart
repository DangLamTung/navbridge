/// Per-device meter for the Google Maps Platform calls NavBridge makes.
///
/// Why a local counter and not "the real number": Google exposes NO API that
/// returns "calls remaining". The authoritative figures live in Cloud Console /
/// Cloud Monitoring and are per PROJECT (they include every other client of
/// that key — including the geocoding scripts in `tool/`). What a driver can
/// actually act on is "has THIS phone used up the free monthly cap", so that is
/// what this measures.
///
/// Free caps and prices match the printed price list (retrieved 2026-10-20):
///   Directions Advanced   5,000 free   $10 / 1,000
///   Compute Routes Pro    5,000 free   $10 / 1,000
///   Geocoding            10,000 free    $5 / 1,000
///   Autocomplete         10,000 free  $2.83 / 1,000
///   Text Search           5,000 free   $32 / 1,000
///   Place Details (Basic) unlimited      free
/// Switch the app to another key and these numbers are wrong — they describe
/// the SKUs, not your billing account.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// One billable Google Maps Platform SKU this app can hit.
class GoogleSku {
  final String id;

  /// Vietnamese label for the settings card.
  final String label;

  /// Billable events included per calendar month (0 = free/unlimited).
  final int freeCap;

  /// USD per 1,000 events once [freeCap] is exceeded.
  final double usdPer1000;

  const GoogleSku(this.id, this.label, this.freeCap, this.usdPer1000);
}

const googleSkus = <GoogleSku>[
  GoogleSku('directions', 'Chỉ đường ô tô (Directions)', 5000, 10),
  GoogleSku('routes_pro', 'Chỉ đường xe máy (Routes Pro)', 5000, 10),
  GoogleSku('geocode', 'Geocode địa chỉ', 10000, 5),
  GoogleSku('autocomplete', 'Gợi ý địa điểm', 10000, 2.83),
  GoogleSku('place_details', 'Chi tiết địa điểm (Basic — free)', 0, 0),
  GoogleSku('nearby_search', 'Tìm quanh đây (Nearby Search)', 5000, 32),
  GoogleSku('text_search', 'Tìm địa điểm (Text Search)', 5000, 32),
];

GoogleSku? skuById(String id) {
  for (final s in googleSkus) {
    if (s.id == id) return s;
  }
  return null;
}

/// `2026-10` — counters roll over on the 1st, like Google's billing month.
String monthKey(DateTime now) =>
    '${now.year}-${now.month.toString().padLeft(2, '0')}';

/// How many events are still inside the free cap (null when the SKU is free).
int? remainingOf(GoogleSku sku, int used) =>
    sku.freeCap <= 0 ? null : (sku.freeCap - used).clamp(0, sku.freeCap);

/// Estimated USD owed for [used] events, ignoring the free cap.
double costOf(GoogleSku sku, int used) {
  if (sku.usdPer1000 <= 0 || sku.freeCap <= 0) return 0;
  final billable = used - sku.freeCap;
  if (billable <= 0) return 0;
  return billable / 1000 * sku.usdPer1000;
}

/// `1.234 / 5.000` style counter line, plus the overage cost when there is one.
String usageText(GoogleSku sku, int used) {
  if (sku.freeCap <= 0) return '$used lượt (miễn phí)';
  final cost = costOf(sku, used);
  final base = '$used / ${sku.freeCap}';
  if (cost <= 0) return base;
  return '$base · vượt hạn mức ≈ \$${cost.toStringAsFixed(2)}';
}

/// Monthly counters, kept in `<appSupport>/api_usage.json`.
class ApiUsage {
  ApiUsage._();

  static String _month = '';
  static final Map<String, int> _counts = {};
  static bool _loaded = false;
  static Timer? _flushTimer;

  /// Injected in tests; prod uses the wall clock.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @visibleForTesting
  static void resetForTest() {
    _month = '';
    _counts.clear();
    _loaded = false;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Resolved once: `getApplicationSupportDirectory` is a plugin call and this
  /// runs on every network path.
  static Future<File?> _file() async {
    final override = fileOverrideForTest;
    if (override != null) return override;
    final cached = _defaultFileSync;
    if (cached != null) return cached;
    try {
      final sup = await getApplicationSupportDirectory();
      final f = File('${sup.path}/api_usage.json');
      _defaultFileSync = f;
      return f;
    } catch (_) {
      return null; // unit tests / no plugin: memory-only
    }
  }

  /// Point the meter at a temp file in tests; null = the real app-support path.
  @visibleForTesting
  static File? fileOverrideForTest;

  static File? _defaultFileSync;

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final f = await _file();
    if (f == null || !f.existsSync()) {
      _month = monthKey(clock());
      return;
    }
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final stored = (j['month'] ?? '') as String;
      final now = monthKey(clock());
      if (stored == now) {
        _month = now;
        final c = (j['counts'] as Map?) ?? const {};
        c.forEach((k, v) {
          if (v is num) _counts['$k'] = v.toInt();
        });
      } else {
        // A new billing month: start from zero, never carry the old counts.
        _month = now;
        _counts.clear();
      }
    } catch (_) {
      _month = monthKey(clock());
    }
  }

  /// Record [n] call(s) against [id]. Fire-and-forget: it must never throw
  /// into a network path or make the caller await disk I/O.
  static Future<void> note(String id, {int n = 1}) async {
    await _ensureLoaded();
    final now = monthKey(clock());
    if (now != _month) {
      // roll the month over on first use after midnight on the 1st
      _month = now;
      _counts.clear();
    }
    _counts[id] = (_counts[id] ?? 0) + n;
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  static Future<void> flush() async {
    final f = await _file();
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'month': _month, 'counts': _counts}));
    } catch (_) {
      // Disk full / read-only: the meter is a nicety, never a blocker.
    }
  }

  /// Calls recorded this month for [id].
  static int usedOf(String id) => _counts[id] ?? 0;

  /// True once the app has counted anything this month (drives the UI hint).
  static bool get hasAny => _counts.values.any((v) => v > 0);

  /// Load the persisted counters (call once at screen open).
  static Future<void> load() => _ensureLoaded();
}
