import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService()
      : player = Player(),
        controller = VideoController(Player()) {
    // Replaced immediately below so the controller and player share one instance.
    controller = VideoController(player);
  }

  final Player player;
  late VideoController controller;

  Future<void> open(String url, {String? title}) async {
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

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
