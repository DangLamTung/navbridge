// Non-web impl: write the document next to the app's other data.
//
// A device has no download directory it may write to, so the trip goes to the
// documents directory — the same place `saveTrip()` puts a finished drive's trip
// (`trip_logger.dart`), which is the point: on a phone the simulation should
// leave its output where a real drive leaves its own.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String> saveTextFile({
  required String text,
  required String fileName,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final f = File('${dir.path}/$fileName');
  await f.writeAsString(text);
  return 'Đã lưu ${f.path} (${(text.length / 1024).round()} KB)';
}
