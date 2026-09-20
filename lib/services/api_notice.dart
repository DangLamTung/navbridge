/// Global one-shot "provider notice" channel.
///
/// Services (e.g. Google Places) that hit a quota/exhaustion error but have no
/// UI `BuildContext` can call [announceApiNotice]; the navigation page listens
/// to [apiNotice] and surfaces it as a SnackBar. Throttled so a burst of
/// identical quota errors (e.g. every search while over quota) only shows once.
library;

import 'package:flutter/foundation.dart';

/// The latest notice to show (null = nothing). Listeners show a SnackBar.
final ValueNotifier<String?> apiNotice = ValueNotifier(null);

String? _lastNotice;
DateTime? _lastShown;

/// Show [msg] as a global SnackBar (deduped within 10 s).
void announceApiNotice(String msg) {
  final now = DateTime.now();
  if (msg == _lastNotice &&
      _lastShown != null &&
      now.difference(_lastShown!) < const Duration(seconds: 10)) {
    return;
  }
  _lastNotice = msg;
  _lastShown = now;
  apiNotice.value = msg;
}

/// Detect a Google Places quota / key exhaustion from an HTTP status + JSON
/// `status` (or raw body) and raise [announceApiNotice] when so.
void noteGoogleQuota({required int statusCode, String? status, String? body}) {
  final s = (status ?? '').toUpperCase();
  final b = (body ?? '').toLowerCase();
  final exhausted =
      statusCode == 429 ||
      s == 'OVER_QUERY_LIMIT' ||
      s == 'RESOURCE_EXHAUSTED' ||
      (s == 'REQUEST_DENIED' && (b.contains('quota') || b.contains('limit'))) ||
      (statusCode == 403 &&
          (b.contains('quota') ||
              b.contains('limit') ||
              b.contains('exhaust') ||
              b.contains('daily')));
  if (!exhausted) return;
  announceApiNotice(
    'Google Places: hạn mức API đã dùng hết. Đang dùng nguồn dữ liệu khác — '
    'kiểm tra GOOGLE_PLACES_KEY / billing.',
  );
}

/// Detect a Vietmap quota / auth failure from an HTTP status + body and
/// raise [announceApiNotice] when so.
void noteVietmapQuota({required int statusCode, String? body}) {
  final b = (body ?? '').toLowerCase();
  final exhausted =
      statusCode == 429 ||
      statusCode == 401 ||
      statusCode == 403 ||
      b.contains('quota') ||
      b.contains('limit') ||
      b.contains('unauthorized');
  if (!exhausted) return;
  announceApiNotice(
    'Vietmap: lỗi xác thực hoặc hết hạn mức API. Đang tự động chuyển key khác.',
  );
}

/// Per-provider timestamp of the last route-fallback notice, so a source that
/// is down cannot pop a SnackBar on every off-route reroute.
final Map<String, DateTime> _lastFallback = {};

/// Announce that routing fell through from [provider] to [next] (null = no
/// provider left, so this attempt failed outright).
///
/// Route fall-throughs used to be `debugPrint`-only, which meant a driver whose
/// Google key expired — or whose phone lost data mid-drive — silently got OSRM
/// geometry, or no route at all, with nothing on screen explaining why.
///
/// Throttled to one notice per provider per minute (on top of
/// [announceApiNotice]'s 10 s dedupe): reroutes can fire repeatedly while a
/// provider is down, and the driver only needs to be told once.
void noteRouteFallback({
  required String provider,
  String? next,
  Object? error,
}) {
  final now = DateTime.now();
  final last = _lastFallback[provider];
  if (last != null && now.difference(last) < const Duration(seconds: 60)) {
    return;
  }
  _lastFallback[provider] = now;
  announceApiNotice(
    next == null
        ? '$provider: không lấy được tuyến đường.'
        : '$provider: lỗi chỉ đường — đang thử $next.',
  );
}
