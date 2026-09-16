import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    // Windows high-bitrate HEVC/Dolby Vision files are safer through mpv's
    // copy-back hardware decode path. It keeps GPU decoding but avoids handing
    // decoder-owned surfaces directly to the Flutter texture/render context,
    // which is a common source of native-process crashes on difficult 4K files.
    controller = Platform.isWindows
        ? VideoController(
            player,
            configuration: const VideoControllerConfiguration(
              hwdec: 'auto-copy-safe',
            ),
          )
        : VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
    await _applyNetworkProfile();
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

  /// Debrify's vetted "Large" VOD buffer rung, without the aggressive
  /// cache-pause/cache-pause-initial settings Pikora experimented with in
  /// v0.3.3. This increases read-ahead for cloud files while preserving normal
  /// startup behaviour.
  Future<void> _applyNetworkProfile() async {
    final dynamic platform = player.platform;
    const properties = <String, String>{
      'demuxer-max-bytes': '256MiB',
      'demuxer-readahead-secs': '120',
      'cache-secs': '120',
    };

    for (final entry in properties.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // Keep playback available even when a backend does not expose one of
        // these native mpv properties.
      }
    }
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
