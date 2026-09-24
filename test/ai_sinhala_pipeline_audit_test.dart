import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player has one source of truth for AI Sinhala mode', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('AiSinhalaRuntimeState _aiState'));
    expect(player, contains('bool get _aiSinhalaRequested => _aiState.requested;'));
    expect(player, contains('bool get _aiSinhalaEnabled => _aiState.enabled;'));
    expect(RegExp(r'_aiSinhalaRequested\s*=(?![=>])').allMatches(player), isEmpty);
    expect(RegExp(r'_aiSinhalaEnabled\s*=(?![=>])').allMatches(player), isEmpty);
  });

  test('legacy complete-file helper still supports exact embedded subtitle extraction', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('));
    expect(startup, contains('_bestNativeEnglishTextTrack()'));
    expect(startup, contains('preferredTrackLabel:'));
    expect(startup, isNot(contains('prepareTrustedTranscriptForNativeClock(')));
    expect(startup, isNot(contains('_captureNativeEnglishSamples()')));
    expect(startup, isNot(contains('OnlineSubtitleService.search(')));
  });

  test('embedded full-file service preserves timing and writes one finished SRT', () {
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

    expect(generated, contains('_fetchEmbeddedEnglishSubtitle('));
    expect(generated, contains('_parseSubtitle(embedded.content)'));
    expect(generated, contains('_translateEntireSubtitle('));
    expect(generated, contains('_writeGeneratedSrt(cacheKey, prepared)'));
    expect(generated, contains("source: 'embedded-exact'"));
    expect(generated, contains("sourceMatch: 'embedded-exact-full-file'"));
  });

  test('complete translation uses bounded parallel batching for faster startup', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start =
        service.indexOf('static Future<void> _translateEntireSubtitle(');
    final end = service.indexOf('static Future<AiPreparedSubtitle?> prepareBuffered', start);
    final translate = service.substring(start, end);

    expect(translate, contains('const batchSize = 96;'));
    expect(translate, contains('const parallelBatches = 3;'));
    expect(translate, contains('await Future.wait<void>'));
    expect(translate, contains('_translateIndicesResilient('));
  });

  test('automatic startup uses progressive native player cues before playback', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      details,
      contains('_legacyCompleteFileAiPreflightEnabled => false'),
    );

    final start = player.indexOf('Future<void> _open()');
    final end = player.indexOf('void _onPlaybackError', start);
    final open = player.substring(start, end);

    expect(open, contains('final useProgressiveNativeCueAi ='));
    expect(open, contains('play: !(aiReady || useProgressiveNativeCueAi)'));
    expect(open, contains('await _activateProgressiveNativeCueAi();'));
    expect(open, contains('await widget.playback.player.play();'));
    expect(
      open,
      isNot(contains('await _prepareAiSinhalaBeforePlayback();')),
    );
  });

  test('automatic path intentionally uses the live native cue translator', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('_activateProgressiveNativeCueAi('));
    expect(player, contains('_enableEmbeddedLiveAiFallback('));
    expect(player, contains('_translateLiveSubtitleCue('));
    expect(player, contains('native-cue-ai-ready'));
    expect(
      player,
      contains('Using the English subtitle track reported by the active player.'),
    );
  });
}
