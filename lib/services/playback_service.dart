import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: 'auto',
      ),
    );
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

  /// PikPak media links are seekable HTTP VOD. Let libmpv build a useful
  /// packet cache before the first frame instead of immediately playing into
  /// an underrun, and automatically pause/rebuffer if the CDN briefly falls
  /// behind. Unsupported properties are intentionally ignored so the service
  /// remains portable across media_kit backends.
  Future<void> _applyVodNetworkTuning() async {
    final dynamic platform = player.platform;
    const properties = <String, String>{
      'cache': 'yes',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '4',
      'cache-secs': '180',
      'demuxer-max-bytes': '384MiB',
      'demuxer-max-back-bytes': '96MiB',
      'demuxer-readahead-secs': '180',
      'stream-buffer-size': '4MiB',
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
