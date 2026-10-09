// Mirrors ffmpeg_kit_flutter_new_https 2.6.x. See README.md.
import 'ffmpeg_kit_config.dart';
import 'session.dart';

export 'session.dart' show FFmpegSession;

class FFmpegKit {
  static Future<FFmpegSession> execute(String command) async =>
      executeWithArguments(FFmpegKitConfig.parseArguments(command));

  static Future<FFmpegSession> executeWithArguments(
    List<String> commandArguments,
  ) async =>
      FFmpegSession(commandArguments);
}
