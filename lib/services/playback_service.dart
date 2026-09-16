import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    // Keep the patched media_kit_video platform defaults. On Windows the
    // patched controller uses mpv's native auto hardware decoder path.
    controller = VideoController(player);
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
  /// Uses Debrify's vetted Large/Extended cloud-VOD profile: two minutes of
  /// read-ahead plus reconnect tolerance, without forcing cache-pause.
  Future<void> _applyNetworkProfile() async {
    final dynamic platform = player.platform;
    const properties = <String, String>{
      // Debrify-vetted Large + Extended profile. Deliberately do not force
      // cache-pause/cache-pause-wait: those can turn ordinary read-ahead into
      // repeated visible stalls on fast cloud VOD.
      'demuxer-max-bytes': '256MiB',
      'demuxer-readahead-secs': '120',
      'cache-secs': '120',
      'network-timeout': '90',
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
