import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    // v0.3.5 used auto-copy-safe to stop difficult 4K HEVC files from taking
    // the process down. That path copies decoded frames back through system RAM
    // and can become the bottleneck on UHD content. Debrify's patched
    // media_kit_video renderer is now pinned in pubspec, so use mpv's supported
    // direct hardware path on Windows for substantially better 4K throughput.
    controller = Platform.isWindows
        ? VideoController(
            player,
            configuration: const VideoControllerConfiguration(
              hwdec: 'auto-safe',
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

  /// Cloud-VOD profile for PikPak playback.
  ///
  /// The 512 MiB forward packet budget is intentionally much larger than the
  /// old 256 MiB profile. mpv continuously reads ahead while playback runs, up
  /// to about five minutes when bitrate and the byte ceiling permit it. If the
  /// CDN briefly falls behind, cache-pause waits for a small cushion before
  /// resuming instead of repeatedly stuttering frame-by-frame.
  Future<void> _applyNetworkProfile() async {
    final dynamic platform = player.platform;
    const properties = <String, String>{
      'cache': 'yes',
      'demuxer-thread': 'yes',
      'demuxer-max-bytes': '512MiB',
      'demuxer-max-back-bytes': '32MiB',
      'demuxer-readahead-secs': '300',
      'cache-secs': '300',
      'cache-pause': 'yes',
      'cache-pause-wait': '3',
      'network-timeout': '60',
      'stream-lavf-o':
          'reconnect=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=10',
    };

    for (final entry in properties.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // A backend may not expose every native mpv property. Playback should
        // still continue with the properties it accepted.
      }
    }
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
