import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PlaybackService {
  PlaybackService()
      : player = Player(
          configuration: PlayerConfiguration(
            // Use one Android playback budget for phone and TV. This keeps
            // the TV player on the same code/profile that is already stable on
            // Android mobile while remaining far below desktop memory usage.
            bufferSize: Platform.isAndroid
                ? 96 * 1024 * 1024
                : 512 * 1024 * 1024,
          ),
        ) {
    controller = VideoController(player);
  }

  final Player player;
  late final VideoController controller;

  Future<void> _applySmartStreamingProfile(String url) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final uri = Uri.tryParse(url);
    final localP2p = uri != null &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
        uri.port == 11470 &&
        uri.pathSegments.length >= 2 &&
        RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(uri.pathSegments.first) &&
        int.tryParse(uri.pathSegments[1]) != null;

    final properties = <String, String>{
      'cache': 'yes',
      'demuxer-readahead-secs': localP2p ? '60' : '180',
      'cache-secs': localP2p ? '60' : '180',
      'network-timeout': '90',
      if (localP2p) 'cache-pause': 'yes',
      if (localP2p) 'cache-pause-initial': 'yes',
      if (localP2p) 'cache-pause-wait': '8',
      // Prefer English whenever the file exposes language-tagged audio tracks.
      // Users can still switch to any other track from Audio & Subtitles.
      'alang': 'eng,en,en-US,en-GB',
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
    bool play = true,
  }) async {
    await _applySmartStreamingProfile(url);
    await player.open(
      Media(
        url,
        httpHeaders: httpHeaders,
        extras: {
          if (title != null) 'title': title,
        },
      ),
      play: play,
    );
  }

  Future<void> stop() => player.stop();

  Future<void> dispose() => player.dispose();
}
