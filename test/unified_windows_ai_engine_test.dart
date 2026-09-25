import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows playback and optional audio extraction share one media transport', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final audio =
        File('lib/services/ai_audio_stt_service.dart').readAsStringSync();
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    final patch =
        File('tools/patch_orvix_stream_server.py').readAsStringSync();

    expect(details, contains('aiSourceUrl: aiSourceUrl ?? playbackUrl'));
    expect(
      audio,
      contains('LocalTorrentService.instance.extractAudioWindow'),
    );
    expect(audio, isNot(contains('OrvixMediaEngineService')));
    expect(torrent, contains("baseUrl = 'http://127.0.0.1:11470'"));
    expect(torrent, contains('Future<List<int>> extractAudioWindow'));
    expect(torrent, contains("'audioWindowExtraction'"));
    expect(torrent, contains("'audioWindowRouteVersion'"));

    expect(patch, contains('"audioWindowExtraction": true'));
    expect(patch, contains('"audioWindowRouteVersion": 1'));
    expect(patch, contains('pub async fn orvix_audio_window'));
    expect(patch, contains('cmd.kill_on_drop(true);'));
    expect(patch, contains('post(routes::subtitles::orvix_audio_window)'));
  });

  test('Windows text subtitles use exact per-event timeline and position rendering', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final parser =
        File('lib/services/native_subtitle_event_parser.dart').readAsStringSync();

    expect(player, contains('static const int _liveAiLeadMs = 6000;'));
    expect(player, contains("'sub-text/ass-full'"));
    expect(player, contains('NativeSubtitleEventParser.parseAssFull(raw)'));
    expect(player, contains('_liveExactCues'));
    expect(player, contains('_liveExactInFlight'));
    expect(player, contains('_refreshLiveExactSubtitle(position)'));
    expect(player, contains("final next = lines.join('\\n');"));
    expect(player, contains('live-exact-ready index='));

    expect(parser, contains("startsWith('dialogue:')"));
    expect(parser, contains('Split only the first 9 commas'));
    expect(parser, contains('result.sort'));
  });

  test('Windows PGS/no-text startup is deliberately held instead of audio guessing', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('bool _windowsAiTextOnlyHeld = false;'));
    expect(player, contains('audio-ai-held phase='));
    expect(
      player,
      contains(
        'Native subtitles will be used instead of the unreliable audio-listening fallback.',
      ),
    );
    expect(
      player,
      contains(
        'AI Sinhala is paused for this source because no readable English SRT/ASS track was exposed.',
      ),
    );
  });
}
