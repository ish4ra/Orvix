import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/embedded_subtitle_extractor_service.dart';

void main() {
  test('cross-platform extractor strongly prefers normal English text tracks', () {
    final english = EmbeddedSubtitleExtractorService.scoreTrackForTesting(
      index: 3,
      codec: 'subrip',
      language: 'eng',
      title: 'English',
    );
    final forced = EmbeddedSubtitleExtractorService.scoreTrackForTesting(
      index: 4,
      codec: 'subrip',
      language: 'eng',
      title: 'English Forced',
      forced: true,
    );
    final commentary = EmbeddedSubtitleExtractorService.scoreTrackForTesting(
      index: 5,
      codec: 'ass',
      language: 'eng',
      title: 'English Commentary',
    );

    expect(english, greaterThan(forced));
    expect(english, greaterThan(commentary));
    expect(english, greaterThan(200));
  });

  test('preferred native track label can identify an otherwise weakly tagged track', () {
    final score = EmbeddedSubtitleExtractorService.scoreTrackForTesting(
      index: 7,
      codec: 'ass',
      title: 'Full SDH',
      preferredTrackLabel: 'English Full SDH ASS',
    );
    expect(score, greaterThan(0));
  });

  test('AI service keeps exact local P2P first and FFmpegKit as cross-platform fallback', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final wrapperStart =
        service.indexOf('static Future<_EmbeddedSubtitleSource?> _fetchEmbeddedEnglishSubtitle(');
    final localStart = service.indexOf(
      'static Future<_EmbeddedSubtitleSource?> _fetchLocalP2pEmbeddedEnglishSubtitle(',
      wrapperStart,
    );
    final wrapper = service.substring(wrapperStart, localStart);

    expect(wrapper, contains('_fetchLocalP2pEmbeddedEnglishSubtitle('));
    expect(wrapper, contains('EmbeddedSubtitleExtractorService.extractEnglishText('));
    expect(
      wrapper.indexOf('_fetchLocalP2pEmbeddedEnglishSubtitle('),
      lessThan(wrapper.indexOf('EmbeddedSubtitleExtractorService.extractEnglishText(')),
    );
  });

  test('Android TV is no longer excluded from complete-file AI Sinhala', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(
      player,
      isNot(contains('widget.allowAiSinhala &&\n          !PlatformProfile.isAndroidTv')),
    );
    expect(
      player,
      isNot(contains('widget.allowAiSinhala && !PlatformProfile.isAndroidTv')),
    );
    expect(details, contains('allowAiSinhala: true'));
  });
  test('single und/default text track is a safe metadata fallback', () {
    expect(
      EmbeddedSubtitleExtractorService.safelyUnlabeledTrackForTesting(
        codec: 'subrip',
        language: 'und',
        title: 'Default',
      ),
      isTrue,
    );
    expect(
      EmbeddedSubtitleExtractorService.safelyUnlabeledTrackForTesting(
        codec: 'subrip',
        language: 'spa',
        title: '',
      ),
      isFalse,
    );
  });

  test('Windows cloud proxy is byte-preflighted before MPV receives it', () {
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();
    final playback =
        File('lib/services/playback_service.dart').readAsStringSync();

    expect(torrent, contains('_remoteProxyHasMediaBytes('));
    expect(torrent, contains("headers['Range'] = 'bytes=0-1'"));
    expect(torrent, contains('response.stream.first'));
    expect(
      playback,
      contains("RegExp(r'^[0-9a-fA-F]{40}\\    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();

    expect(ai, contains('_fetchOrvixRemoteEmbeddedEnglishSubtitle('));
    expect(ai, contains('/orvix/remote/subtitlesTracks'));
    expect(ai, contains('/orvix/remote/embedded/'));
    expect(ai, contains('remoteEmbeddedSubtitles'));
    expect(details, contains('LocalTorrentService.instance.proxyRemoteUrl('));
    expect(details, contains('Opening through the Orvix stream engine'));
    expect(torrent, contains("Uri.parse('\$baseUrl/proxy/')"));
    expect(torrent, contains('remoteSubtitleRouteVersion'));
  });

  test('unlabeled extracted dialogue must actually look English', () {
    expect(
      EmbeddedSubtitleExtractorService.looksLikeEnglishSubtitleForTesting(
        '''1
00:00:01,000 --> 00:00:03,000
What are you doing here?

2
00:00:04,000 --> 00:00:06,000
I know that you want to get out of there.

3
00:00:07,000 --> 00:00:09,000
But this is not the way we do things.''',
      ),
      isTrue,
    );
    expect(
      EmbeddedSubtitleExtractorService.looksLikeEnglishSubtitleForTesting(
        '''1
00:00:01,000 --> 00:00:03,000
Hola amigo buenos días.

2
00:00:04,000 --> 00:00:06,000
Gracias por venir esta noche.''',
      ),
      isFalse,
    );
  });

}
)"),
    );
  });

  test('Windows debrid path uses the same Orvix native stream engine family', () {
    final ai =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final torrent =
        File('lib/services/local_torrent_service.dart').readAsStringSync();

    expect(ai, contains('_fetchOrvixRemoteEmbeddedEnglishSubtitle('));
    expect(ai, contains('/orvix/remote/subtitlesTracks'));
    expect(ai, contains('/orvix/remote/embedded/'));
    expect(ai, contains('remoteEmbeddedSubtitles'));
    expect(details, contains('LocalTorrentService.instance.proxyRemoteUrl('));
    expect(details, contains('Opening through the Orvix stream engine'));
    expect(torrent, contains("Uri.parse('\$baseUrl/proxy/')"));
    expect(torrent, contains('remoteSubtitleRouteVersion'));
  });

  test('unlabeled extracted dialogue must actually look English', () {
    expect(
      EmbeddedSubtitleExtractorService.looksLikeEnglishSubtitleForTesting(
        '''1
00:00:01,000 --> 00:00:03,000
What are you doing here?

2
00:00:04,000 --> 00:00:06,000
I know that you want to get out of there.

3
00:00:07,000 --> 00:00:09,000
But this is not the way we do things.''',
      ),
      isTrue,
    );
    expect(
      EmbeddedSubtitleExtractorService.looksLikeEnglishSubtitleForTesting(
        '''1
00:00:01,000 --> 00:00:03,000
Hola amigo buenos días.

2
00:00:04,000 --> 00:00:06,000
Gracias por venir esta noche.''',
      ),
      isFalse,
    );
  });

}
