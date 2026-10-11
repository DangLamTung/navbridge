// Fallback impl. Unreachable in this app (the web and io impls cover every
// target Flutter builds for); it exists so `save_text.dart` compiles anywhere,
// and it says so rather than failing silently.

Future<String> saveTextFile({
  required String text,
  required String fileName,
}) async {
  return 'Nền tảng này không lưu được tệp ($fileName, ${text.length} ký tự)';
}
