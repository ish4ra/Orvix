import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> open(String url, {String? title}) async {
    await _applyVodNetworkTuning();
    await player.open(
      Media(
        url,
        extras: {
          if (title != null) 'title': title,
        },
      ),
      play: true,
    );
  }

  /// PikPak media links are seekable HTTP VOD. Give libmpv enough read-ahead
  /// for high-bitrate Blu-ray/Remux playback and let ffmpeg reconnect cleanly
  /// on transient CDN/network drops. Unsupported properties are intentionally
  /// ignored so the same service remains portable across media_kit backends.
  Future<void> _applyVodNetworkTuning() async {
    final dynamic platform = player.platform;
    const properties = <String, String>{
      'cache': 'yes',
      'demuxer-max-bytes': '256MiB',
      'demuxer-max-back-bytes': '64MiB',
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
        // A backend may not expose every mpv property. Playback should still
        // proceed with the properties that were accepted.
      }
    }
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
