import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows AI uses one native media transport end to end', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final audio =
        File('lib/services/ai_audio_stt_service.dart').readAsStringSync();
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    final patch =
        File('tools/patch_orvix_stream_server.py').readAsStringSync();

    // Whatever URL MPV actually receives must also be the URL used for AI
    // audio extraction. This prevents signed cloud URLs and localhost proxies
    // from silently diverging.
    expect(details, contains('aiSourceUrl: aiSourceUrl ?? playbackUrl'));

    // The active Windows fallback is owned by the same stream server that owns
    // Free P2P and cloud proxying. The old standalone 11471 helper is legacy
    // only and must not be imported by the active audio/STT service.
    expect(
      audio,
      contains('LocalTorrentService.instance.extractAudioWindow'),
    );
    expect(audio, isNot(contains('OrvixMediaEngineService')));
    expect(torrent, contains("baseUrl = 'http://127.0.0.1:11470'"));
    expect(torrent, contains('Future<List<int>> extractAudioWindow'));
    expect(torrent, contains("'audioWindowExtraction'"));
    expect(torrent, contains("'audioWindowRouteVersion'"));

    // The native engine owns FFmpeg, so Flutter receives bounded AAC bytes or a
    // normal HTTP error instead of hosting FFmpeg/native callbacks in-process.
    expect(patch, contains('"audioWindowExtraction": true'));
    expect(patch, contains('"audioWindowRouteVersion": 1'));
    expect(patch, contains('pub async fn orvix_audio_window'));
    expect(patch, contains('cmd.kill_on_drop(true);'));
    expect(patch, contains('post(routes::subtitles::orvix_audio_window)'));
  });

  test('live native text cues are translated once and ahead of presentation', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('static const int _liveAiLeadMs = 3000;'));
    expect(player, contains('String? _lastLiveCueKey;'));
    expect(player, contains("final cueKey = '\$dedupClockMs|\$normalized';"));
    expect(player, contains('if (_lastLiveCueKey == cueKey)'));
    expect(player, contains('live-cue-duplicate'));
    expect(player, contains('cueStartMs: nativeStartMs'));
    expect(player, contains('cueEndMs: nativeEndMs'));
  });
}
