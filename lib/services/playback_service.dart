import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService() : player = Player() {
    // Preserve the patched media_kit platform defaults. In particular, do not
    // force a global cache/reconnect profile: PikPak's signed media URLs are
    // already VOD-optimized and mpv's defaults are more reliable across
    // original files and cloud renditions.
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> open(
    String url, {
    String? title,
    Map<String, String>? httpHeaders,
  }) async {
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
