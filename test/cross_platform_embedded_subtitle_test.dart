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
}
