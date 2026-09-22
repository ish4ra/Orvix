import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic AI Sinhala trusts only the complete embedded subtitle file', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('));
    expect(startup, isNot(contains('prepareGeneratedSinhalaFile(')));
    expect(startup, isNot(contains('OnlineSubtitleService.search(')));
    expect(startup, isNot(contains('prepareTrustedTranscriptForNativeClock(')));
  });

  test('embedded extractor prefers the selected English track identity', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains('String? preferredTrackLabel'));
    expect(service, contains('_embeddedEnglishTrackScore('));
    expect(service, contains('preferredTrackLabel: preferredTrackLabel'));
    expect(service, contains('final targetSdh = target.contains'));
  });

  test('generated cache is keyed by the exact embedded subtitle contents', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'prepareGeneratedSinhalaFromEmbeddedSubtitle',
    );
    final end = service.indexOf(
      'prepareGeneratedSinhalaFromOnlineSubtitle',
      start,
    );
    final generated = service.substring(start, end);

    expect(generated, contains('sha256.convert(utf8.encode(embedded.content))'));
    expect(generated, contains("'embedded-full|\$contentDigest|"));
    expect(generated, contains('_cachedGeneratedFile(cacheKey)'));
  });

  test('manual AI enable reuses the same strict full-file preparation path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf(
      'Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled)',
    );
    final end =
        player.indexOf('Future<void> _loadSubtitlePreferences()', start);
    final toggle = player.substring(start, end);

    expect(toggle, contains('await _prepareAiSinhalaBeforePlayback();'));
    expect(toggle, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(toggle, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });
}
