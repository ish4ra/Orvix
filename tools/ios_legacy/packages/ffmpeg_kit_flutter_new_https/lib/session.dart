// Mirrors the parts of ffmpeg_kit_flutter_new_https 2.6.x sessions that
// Orvix reads. See README.md.
import 'return_code.dart';

/// A session that never ran: FFmpeg is not bundled in the Legacy iOS build.
abstract class Session {
  Session(this.arguments);

  /// Exit code reported for every unavailable FFmpeg/FFprobe session.
  static const int unavailableReturnCode = 1;

  final List<String> arguments;

  List<String> getArguments() => List.unmodifiable(arguments);

  Future<ReturnCode?> getReturnCode() async =>
      ReturnCode(unavailableReturnCode);

  Future<String?> getOutput() async => null;

  Future<String?> getFailStackTrace() async =>
      'FFmpeg is not available in the Orvix Legacy iOS build.';
}

class FFmpegSession extends Session {
  FFmpegSession(super.arguments);
}

class FFprobeSession extends Session {
  FFprobeSession(super.arguments);
}
