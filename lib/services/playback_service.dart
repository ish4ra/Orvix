import 'dart:io';

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

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
    await _applySmartBuffer();
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

  Future<void> _applySmartBuffer() async {
    if (!Platform.isWindows) return;
    try {
      await player.handle;
      final dynamic platform = player.platform;
      if (platform == null) return;
      await platform.setProperty('demuxer-max-bytes', '${512 * 1024 * 1024}', waitForInitialization: false);
      await platform.setProperty('demuxer-max-back-bytes', '${128 * 1024 * 1024}', waitForInitialization: false);
      await platform.setProperty('demuxer-readahead-secs', '180', waitForInitialization: false);
      await platform.setProperty('cache-secs', '180', waitForInitialization: false);
      await platform.setProperty('network-timeout', '90', waitForInitialization: false);
      await platform.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',
        waitForInitialization: false,
      );
    } catch (_) {
      // Keep playback functional if a backend ignores one of the tuning knobs.
    }
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
