/// Persistent background isolate that keeps the offline point DBs (cameras,
/// road signs) resident, so the per-second navigation checks only transfer
/// tiny args (current position + geometry) instead of deep-copying the whole
/// 8.6k-camera / 11k-sign list onto the MAIN THREAD every GPS fix.
///
/// WHY: `compute()` spawns a NEW isolate per call and re-sends the full DB
/// each time. On a long route that copy ran every second (camera check +
/// sign check) — ~90 ms of main-thread copy per call on a desktop, 3-5x
/// that on a low-end phone. Over 5 minutes that's ~22 s of main-thread CPU
/// in `[anon:dart-code]`, exactly the "app isn't responding" signature seen
/// on long routes. Holding the DB in ONE long-lived isolate removes that
/// per-second copy entirely.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'offline_cameras.dart';
import 'offline_road_signs.dart';
import 'offline_scan.dart';

/// Which offline DB a query targets.
enum _Kind { cameras, signs }

/// Collapse the SAME physical sign recorded by overlapping sources (Waze /
/// VietMap / DATMAP) at a few-metre offset, so the nav map and the sign
/// announcement don't show a stack of identical icons for one real sign.
///
/// Keyed by KIND ONLY within a ~100 m radius (per user: "open to 100m, same
/// kind is ok too") — the driver wants ONE icon per sign post, so an 80 and a
/// 90 recorded at the same post by different sources collapse to a single sign
/// rather than stacking. The road-info/statutory layer still carries the
/// per-segment limit. A STOP and a speed sign at one post are different kinds
/// → both kept. Keeps the FIRST (nearest, since the stage input is
/// route-ordered).
List<SignAhead> dedupSignAhead(List<SignAhead> ahead) {
  if (ahead.isEmpty) return ahead;
  final kept = <(RoadSign, double)>[];
  for (final a in ahead) {
    if (!_signKept(kept, a.sign)) kept.add((a.sign, a.routeMeters));
  }
  return [for (final (s, m) in kept) SignAhead(sign: s, routeMeters: m)];
}

/// Same as [dedupSignAhead] but for a bare [RoadSign] list (the route map
/// layer, which isn't route-ordered) — collapse same-kind signs within a
/// ~100 m radius so one physical sign (recorded by several sources) renders
/// as a single icon.
List<RoadSign> dedupRoadSigns(List<RoadSign> signs) {
  if (signs.isEmpty) return signs;
  final kept = <(RoadSign, double)>[];
  for (final s in signs) {
    if (!_signKept(kept, s)) kept.add((s, 0));
  }
  return [for (final (s, _) in kept) s];
}

/// Collapse the SAME physical camera recorded by overlapping sources (Waze /
/// VietMap EDOG / police / OSM) at a few-metre offset, so the nav map and
/// camera alert don't show a stack of identical icons for one camera.
///
/// Keyed by FOCUS ONLY within a ~100 m radius (same rule as the signs: "same
/// kind is ok too"). A red-light cam and a speed cam at the same spot are
/// different focus → both kept. Keeps the FIRST (nearest, since the route-ahead
/// input is along-route ordered).
List<CameraAhead> dedupCameraAhead(List<CameraAhead> ahead) {
  if (ahead.isEmpty) return ahead;
  final kept = <(OfflineCamera, double)>[];
  for (final a in ahead) {
    if (!_camKept(kept, a.camera)) kept.add((a.camera, a.routeMeters));
  }
  return [for (final (c, m) in kept) CameraAhead(camera: c, routeMeters: m)];
}

/// Same as [dedupCameraAhead] but for a bare [OfflineCamera] list (the route
/// map layer / near-point layer) — collapse same-focus cameras within a
/// ~100 m radius so one physical camera renders as a single icon.
List<OfflineCamera> dedupCameras(List<OfflineCamera> cams) {
  if (cams.isEmpty) return cams;
  final kept = <(OfflineCamera, double)>[];
  for (final c in cams) {
    if (!_camKept(kept, c)) kept.add((c, 0));
  }
  return [for (final (c, _) in kept) c];
}

/// True if a same-focus [OfflineCamera] already sits within ~100 m of the
/// kept list. Distinct focus always pass (speed + red_light at one spot are
/// both kept).
bool _camKept(List<(OfflineCamera, double)> kept, OfflineCamera c) {
  if (kept.isEmpty) return false;
  for (final (k, _) in kept) {
    if (k.focus != c.focus) continue;
    if (_approxDistM(k.lat, k.lng, c.lat, c.lng) < 100) return true;
  }
  return false;
}

/// True if a same-kind [RoadSign] already sits within ~100 m of the kept
/// list. Distinct kinds always pass (STOP + speed at one post are both kept).
bool _signKept(List<(RoadSign, double)> kept, RoadSign s) {
  if (kept.isEmpty) return false;
  for (final (k, _) in kept) {
    if (k.kind != s.kind) continue;
    if (_approxDistM(k.lat, k.lng, s.lat, s.lng) < 100) return true;
  }
  return false;
}

/// Approximate metres between two lat/lng (equirectangular — fine at ≤ a few
/// hundred metres, which is all this near-dup radius test needs).
double _approxDistM(double la1, double lo1, double la2, double lo2) {
  const mPerDegLat = 111320.0;
  final lat = (la1 - la2) * mPerDegLat;
  // cos(VN lat ~18°) ≈ 0.95; using 0.95 keeps the radius honest at the
  // latitudes we care about.
  final lng = (lo1 - lo2) * mPerDegLat * 0.95;
  return math.sqrt(lat * lat + lng * lng);
}

/// Init: main → worker, ships the DBs once.
class _InitMsg {
  final SendPort replyPort;
  final List<OfflineCamera> cameras;
  final List<RoadSign> signs;
  _InitMsg(this.replyPort, this.cameras, this.signs);
}

/// A query for points AHEAD of `current` along `geometry`.
class _QueryAhead {
  final int id;
  final SendPort replyPort;
  final _Kind kind;
  final LatLng current;
  final List<LatLng> geometry;
  final double maxAheadMeters;
  _QueryAhead(
    this.id,
    this.replyPort,
    this.kind,
    this.current,
    this.geometry,
    this.maxAheadMeters,
  );
}

/// A query for points NEAR the whole route polyline.
class _QueryNear {
  final int id;
  final SendPort replyPort;
  final _Kind kind;
  final List<LatLng> geometry;
  final double corridorMeters;
  _QueryNear(
    this.id,
    this.replyPort,
    this.kind,
    this.geometry,
    this.corridorMeters,
  );
}

/// Reply: worker → main, `result` is `List<(int, double)>` of indices into
/// the corresponding DB plus along-route meters.
class _Reply {
  final int id;
  final Object? result;
  _Reply(this.id, this.result);
}

/// Singleton access to the persistent scan isolate.
class OfflineScanIsolate {
  OfflineScanIsolate._();
  static final OfflineScanIsolate instance = OfflineScanIsolate._();

  Isolate? _isolate;
  SendPort? _send;
  final ReceivePort _receive = ReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  int _seq = 0;
  // Memoised initialisation so two concurrent queries (cameras + signs fire
  // together on the first fix) never both reach `_receive.listen()` on the
  // single-subscription ReceivePort (which would throw "Bad state").
  Future<void>? _initFuture;

  Future<void> _ensure() async {
    if (_initFuture != null) return _initFuture!;
    final fresh = _doEnsure();
    _initFuture = fresh;
    try {
      await fresh;
    } catch (_) {
      // Don't memoise a failed init: let the next query retry.
      if (identical(_initFuture, fresh)) _initFuture = null;
      rethrow;
    }
  }

  Future<void> _doEnsure() async {
    if (_send != null) return;
    // Load the DBs once here (rootBundle isn't available in a raw isolate).
    // Both loaders are idempotent/cached, so this is a one-time cost.
    final cameras = await loadOfflineCameras();
    final signs = await loadOfflineRoadSigns();
    final handshake = ReceivePort();
    _isolate = await Isolate.spawn(_workerEntry, handshake.sendPort);
    _send = await handshake.first as SendPort;
    _send!.send(_InitMsg(_receive.sendPort, cameras, signs));
    _receive.listen((Object? msg) {
      if (msg is _Reply) {
        final c = _pending.remove(msg.id);
        if (c != null && !c.isCompleted) c.complete(msg.result);
      }
    });
  }

  Future<Object?> _query<T>(T Function(int id, SendPort reply) make) async {
    await _ensure();
    final id = _seq++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send!.send(make(id, _receive.sendPort));
    return c.future;
  }

  /// Cameras ahead of [current] along [geometry], ordered by along-route
  /// distance, limited to [maxAheadMeters]. Per-second nav check.
  Future<List<CameraAhead>> camerasAhead(
    LatLng current,
    List<LatLng> geometry, {
    double maxAheadMeters = 1500,
  }) async {
    if (geometry.length < 2) return const [];
    final res = await _query(
      (id, reply) => _QueryAhead(
        id,
        reply,
        _Kind.cameras,
        current,
        geometry,
        maxAheadMeters,
      ),
    );
    final list = (res as List?) ?? const [];
    final cams = await loadOfflineCameras();
    // Kept strictly ordered by along-route distance: every consumer reads this
    // as "the cameras ahead, nearest first". The ALERT then picks the most
    // IMPORTANT one with [mostImportantCameraAhead] instead of `.first`.
    return dedupCameraAhead([
      for (final (i, m) in list.cast<(int, double)>())
        CameraAhead(camera: cams[i], routeMeters: m),
    ]);
  }

  /// Signs ahead of [current] along [geometry].
  Future<List<SignAhead>> signsAhead(
    LatLng current,
    List<LatLng> geometry, {
    double maxAheadMeters = 1500,
  }) async {
    if (geometry.length < 2) return const [];
    final res = await _query(
      (id, reply) => _QueryAhead(
        id,
        reply,
        _Kind.signs,
        current,
        geometry,
        maxAheadMeters,
      ),
    );
    final list = (res as List?) ?? const [];
    final signs = await loadOfflineRoadSigns();
    final ahead = [
      for (final (i, m) in list.cast<(int, double)>())
        SignAhead(sign: signs[i], routeMeters: m),
    ];
    return dedupSignAhead(ahead);
  }

  /// Cameras within [corridorMeters] of the whole route (map layer).
  Future<List<OfflineCamera>> camerasNear(
    List<LatLng> geometry, {
    double corridorMeters = 200,
  }) async {
    if (geometry.length < 2) return const [];
    final res = await _query(
      (id, reply) =>
          _QueryNear(id, reply, _Kind.cameras, geometry, corridorMeters),
    );
    final list = (res as List?) ?? const [];
    final cams = await loadOfflineCameras();
    return dedupCameras([for (final i in list.cast<int>()) cams[i]]);
  }

  /// Signs within [corridorMeters] of the whole route (map layer).
  Future<List<RoadSign>> signsNear(
    List<LatLng> geometry, {
    double corridorMeters = 200,
  }) async {
    if (geometry.length < 2) return const [];
    final res = await _query(
      (id, reply) =>
          _QueryNear(id, reply, _Kind.signs, geometry, corridorMeters),
    );
    final list = (res as List?) ?? const [];
    final signs = await loadOfflineRoadSigns();
    return dedupRoadSigns([for (final i in list.cast<int>()) signs[i]]);
  }

  /// Dispose the isolate (shutdown).
  void dispose() {
    _isolate?.kill();
    _isolate = null;
    _send = null;
    // Force the next query to re-initialise a fresh isolate + send port
    // instead of completing against the killed isolate's stale send port.
    _initFuture = null;
  }
}

/// Worker entry: receive the DBs once, then serve ahead/near queries.
void _workerEntry(SendPort initial) {
  final port = ReceivePort();
  initial.send(port.sendPort);
  List<OfflineCamera>? cams;
  List<RoadSign>? signs;

  void serve(Object? msg) {
    if (msg is _InitMsg) {
      cams = msg.cameras;
      signs = msg.signs;
      return;
    }
    if (msg is _QueryAhead) {
      final Object? res;
      switch (msg.kind) {
        case _Kind.cameras:
          res = pointsAheadOnRoute<OfflineCamera>((
            msg.current,
            msg.geometry,
            cams ?? const [],
            msg.maxAheadMeters,
          ));
        case _Kind.signs:
          res = pointsAheadOnRoute<RoadSign>((
            msg.current,
            msg.geometry,
            signs ?? const [],
            msg.maxAheadMeters,
          ));
      }
      msg.replyPort.send(_Reply(msg.id, res));
      return;
    }
    if (msg is _QueryNear) {
      final Object? res;
      switch (msg.kind) {
        case _Kind.cameras:
          res = pointsNearRoute<OfflineCamera>((
            msg.geometry,
            cams ?? const [],
            msg.corridorMeters,
          ));
        case _Kind.signs:
          res = pointsNearRoute<RoadSign>((
            msg.geometry,
            signs ?? const [],
            msg.corridorMeters,
          ));
      }
      msg.replyPort.send(_Reply(msg.id, res));
    }
  }

  port.listen(serve);
}
