import 'dart:io';

/// Small local-only diagnostic trace for the AI Sinhala startup pipeline.
///
/// The trace deliberately records stages and provider/source classes only.
/// Signed playback URLs, query strings, access tokens and subtitle text are
/// never written to disk.
class AiSinhalaTraceService {
  const AiSinhalaTraceService._();

  static Future<void> _writeTail = Future<void>.value();

  static Future<void> write(String message) {
    if (!Platform.isWindows) return Future<void>.value();

    final next = _writeTail.then((_) => _writeNow(message));
    _writeTail = next.catchError((_) {});
    return next;
  }

  static Future<void> _writeNow(String message) async {
    try {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.trim().isEmpty) return;

      final directory = Directory(
        '${localAppData.trim()}${Platform.pathSeparator}Orvix'
        '${Platform.pathSeparator}logs',
      );
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}ai-sinhala.log',
      );

      // Keep the trace bounded so repeated playback tests cannot grow it
      // forever. Start a fresh trace after roughly 1 MiB.
      if (await file.exists() && await file.length() > 1024 * 1024) {
        await file.writeAsString('', flush: true);
      }

      final now = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$now] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never interfere with playback.
    }
  }

  static void writeCrashSync(String message) {
    if (!Platform.isWindows) return;
    try {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.trim().isEmpty) return;
      final directory = Directory(
        '${localAppData.trim()}${Platform.pathSeparator}Orvix'
        '${Platform.pathSeparator}logs',
      );
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final file = File(
        '${directory.path}${Platform.pathSeparator}ai-sinhala.log',
      );
      final now = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$now] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  static String safeHost(String? rawUrl) {
    final uri = Uri.tryParse(rawUrl ?? '');
    if (uri == null) return 'invalid';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
}
