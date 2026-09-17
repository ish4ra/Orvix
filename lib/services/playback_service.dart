import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService()
      : player = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 512 * 1024 * 1024,
          ),
        ) {
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> _applySmartStreamingProfile() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    const properties = <String, String>{
      'cache': 'yes',
      'demuxer-readahead-secs': '180',
      'cache-secs': '180',
      'network-timeout': '90',
      'stream-lavf-o':
          'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',
    };
    for (final entry in properties.entries) {
      try {
        await platform.setProperty(
          entry.key,
          entry.value,
          waitForInitialization: false,
        );
      } catch (_) {
        // An unsupported mpv/ffmpeg option must never block playback.
      }
    }
  }

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
    await _applySmartStreamingProfile();
    await player.open(
      Media(
        url,
        httpHeaders: httpHeaders,
        extras: {
          if (title != null) 'title': title,
        },
      ),
      play: true,
    );
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
