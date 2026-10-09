// Mirrors ffmpeg_kit_flutter_new_https 2.6.x. See README.md.
import 'log_callback.dart';
import 'log_redirection_strategy.dart';

class FFmpegKitConfig {
  static LogRedirectionStrategy _strategy =
      LogRedirectionStrategy.printLogsWhenNoCallbacksDefined;

  static void setLogRedirectionStrategy(
    LogRedirectionStrategy logRedirectionStrategy,
  ) {
    _strategy = logRedirectionStrategy;
  }

  static LogRedirectionStrategy getLogRedirectionStrategy() => _strategy;

  // FFmpeg never runs in this build, so there are no logs to deliver.
  static void enableLogCallback([LogCallback? logCallback]) {}

  static List<String> parseArguments(String command) => command
      .split(RegExp(r'\s+'))
      .where((argument) => argument.isNotEmpty)
      .toList(growable: false);
}
