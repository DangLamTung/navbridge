/// Dump the Dart stack of all isolates on a running Flutter app via the
/// Dart VM service. Use while the app is FROZEN to see what the main isolate
/// is stuck doing.
///
/// Usage: dart run tool/vm_dump.dart PORT AUTH_TOKEN
///   port/auth come from logcat: "Dart VM service is listening on
///   `http://127.0.0.1:PORT/AUTH/`=" — first forward: `adb forward tcp:PORT tcp:PORT`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args[0];
  final auth = args[1];
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/$auth/ws');
  final pending = <String, Completer<Map<String, dynamic>>>{};
  final isolates = <String>[];
  var nextId = 0;

  ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = msg['id'];
    if (id != null) {
      final c = pending[id];
      if (c != null) {
        c.complete(msg);
        pending.remove(id);
      }
    }
  });

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${nextId++}';
    final c = Completer<Map<String, dynamic>>();
    pending[id] = c;
    ws.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params ?? {},
      }),
    );
    return c.future;
  }

  final vm = await call('getVM');
  for (final iso in (vm['result']['isolates'] as List)) {
    isolates.add((iso as Map)['id'] as String);
  }
  for (final id in isolates) {
    try {
      final info = await call('getIsolate', {'isolateId': id});
      final name = info['result']?['name'] ?? '?';
      stdout.writeln('ISOLATE $id  name=$name');
    } catch (e) {
      stdout.writeln('ISOLATE $id  (getIsolate failed: $e)');
    }
  }
  // Pause every isolate so getStack works, then retry until frames appear.
  for (final id in isolates) {
    try {
      await call('pause', {'isolateId': id});
    } catch (_) {}
  }
  for (final id in isolates) {
    List frames = const [];
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future.delayed(const Duration(milliseconds: 1000));
      final st = await call('getStack', {'isolateId': id});
      final enc = jsonEncode(st);
      stdout.writeln(
        '  RAW getStack: ${enc.length > 800 ? enc.substring(0, 800) : enc}',
      );
      frames = (st['result']?['frames'] as List?) ?? const [];
      if (frames.isNotEmpty) break;
      stdout.writeln('  (attempt ${attempt + 1}: no frames yet, retrying…)');
    }
    stdout.writeln('=== STACK $id ===');
    for (final f in frames.take(60)) {
      final fn = f['function']?['name'] ?? '?';
      final loc = f['location'];
      final uri = (loc?['script']?['uri'] ?? '') as String;
      final short = uri.replaceFirst('file://', '');
      final line = loc?['line'] ?? 0;
      stdout.writeln('  $fn  ($short:$line)');
    }
    try {
      await call('resume', {'isolateId': id});
    } catch (_) {}
  }
  await ws.close();
  exit(0);
}
