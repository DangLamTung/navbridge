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

import 'package:latlong2/latlong.dart';

import 'offline_cameras.dart';
import 'offline_road_signs.dart';
import 'offline_scan.dart';

/// Which offline DB a query targets.
enum _Kind { cameras, signs }

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

  Future<void> _ensure() async {
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
    return [
      for (final (i, m) in list.cast<(int, double)>())
        CameraAhead(camera: cams[i], routeMeters: m),
    ];
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
    return [
      for (final (i, m) in list.cast<(int, double)>())
        SignAhead(sign: signs[i], routeMeters: m),
    ];
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
    return [for (final i in list.cast<int>()) cams[i]];
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
    return [for (final i in list.cast<int>()) signs[i]];
  }

  /// Dispose the isolate (shutdown).
  void dispose() {
    _isolate?.kill();
    _isolate = null;
    _send = null;
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
