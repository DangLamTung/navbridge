// Web impl: a real browser download. The trip JSON becomes a file the user can
// audit with the same offline tools that read `docs/trips/**` — no server, no
// harness, no copy-paste out of a console.
//
// `dart:html` is deprecated for new code but is the only browser DOM API
// available without adding a package (`package:web`) to a release build that
// otherwise has no web dependencies at all. It is confined to this one file,
// which is only compiled for web (`save_text.dart`).
// ignore_for_file: deprecated_member_use

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Hand [text] to the browser as a download named [fileName]. Returns a short
/// message for the console to show.
Future<String> saveTextFile({
  required String text,
  required String fileName,
}) async {
  final bytes = utf8.encode(text);
  final blob = html.Blob(<Object>[bytes], 'application/json');
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    (html.AnchorElement(href: url)
          ..download = fileName
          ..style.display = 'none')
        .click();
  } finally {
    // The download has already started; revoking keeps the object URL from
    // pinning the trip in memory for the rest of the session.
    html.Url.revokeObjectUrl(url);
  }
  return 'Đã tải $fileName (${(bytes.length / 1024).round()} KB)';
}
