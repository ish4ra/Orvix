// Mirrors ffmpeg_kit_flutter_new_https 2.6.x. See README.md.
import 'ffmpeg_kit_config.dart';
import 'session.dart';

export 'session.dart' show FFprobeSession;

class FFprobeKit {
  static Future<FFprobeSession> execute(String command) async =>
      executeWithArguments(FFmpegKitConfig.parseArguments(command));

  static Future<FFprobeSession> executeWithArguments(
    List<String> commandArguments,
  ) async =>
      FFprobeSession(commandArguments);
}
