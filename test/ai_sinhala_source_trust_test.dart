import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'automatic AI Sinhala keeps local P2P on exact embedded then strict fingerprint fallback',
      () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('));
    expect(startup, contains('embeddedUnavailable'));
    expect(startup, contains('prepareGeneratedSinhalaFile('));
    expect(startup, contains('expectedSizeBytes: widget.expectedSizeBytes'));
    expect(startup, contains('expectedVideoHash: widget.expectedVideoHash'));

    // Automatic mode may use only exact-file evidence. It must never drop to
    // ranked title/release guesses after embedded extraction fails.
    expect(startup, isNot(contains('OnlineSubtitleService.search(')));
    expect(startup, isNot(contains('prepareTrustedTranscriptForNativeClock(')));

    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();
    expect(service, contains('_probeLocalOpenSubtitlesHash('));
    expect(service, contains('_fetchExactRestSubtitle('));
    expect(
      service,
      contains("'rest-moviehash+moviebytesize-generated-srt'"),
    );
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

  test('embedded extraction requires the Orvix exact-file server capability', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    expect(service, contains("path: '/orvix/capabilities'"));
    expect(service, contains("decoded['exactFileEmbeddedSubtitles'] != true"));
    expect(service, contains("decoded['exactSubtitleRouteVersion'] != 1"));
    expect(service, contains("decoded['orvixExactFile'] != true"));
    expect(service, contains("response.headers['x-orvix-exact-file'] != '1'"));
    expect(service, isNot(contains('_guessStreamServerPrimaryVideoIndex(')));
  });

  test('debrid/direct fallback is isolated from the local P2P exact path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final helperStart = player.indexOf(
      'Future<AiGeneratedSubtitleFile> _prepareRemoteDirectAiFallback()',
    );
    final helperEnd = player.indexOf(
      'Future<bool> _prepareAiSinhalaBeforePlayback()',
      helperStart,
    );
    final helper = player.substring(helperStart, helperEnd);

    expect(helper, contains('if (_localP2pStream || widget.item == null)'));
    expect(helper, contains('_captureNativeEnglishSamples()'));
    expect(helper, contains('OnlineSubtitleService.search('));
    expect(helper, contains('includeTranscriptFallbacks: true'));
    expect(
      helper,
      contains('prepareGeneratedSinhalaFromNativeCalibration('),
    );

    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final prepareEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', prepareStart);
    final prepare = player.substring(prepareStart, prepareEnd);

    expect(prepare, contains('if (_localP2pStream) rethrow;'));
    expect(prepare, contains('generated = await _prepareRemoteDirectAiFallback();'));
  });

}
