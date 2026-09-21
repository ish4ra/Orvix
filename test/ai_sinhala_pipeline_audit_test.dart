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

  test('automatic startup never trusts online timing or loads an external Sinhala track', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('prepareTrustedTranscriptForNativeClock('));
    expect(startup, contains('_captureNativeEnglishSamples()'));
    expect(startup, contains('videoHash: widget.expectedVideoHash'));
    expect(startup, contains('includeTranscriptFallbacks: true'));
    expect(
      startup,
      contains('prepareTranslatedTranscriptForNativeTiming('),
    );
    expect(startup, isNot(contains('prepareGeneratedSinhalaFile(')));
    expect(startup, isNot(contains('final chosen = english.first;')));
  });

  test('actual playback cue handler never performs network translation', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _handleEmbeddedSubtitleCue(List<String> lines)');
    final end =
        player.indexOf('Future<void> _registerLiveTranslationFailure(', start);
    final handler = player.substring(start, end);

    expect(handler, contains('matchSourceCueRange('));
    expect(handler, contains('_nativeAiMatchIndex'));
    expect(handler, isNot(contains('translateCue(')));
    expect(handler, isNot(contains('ensureTranslatedAround(')));
    expect(handler, isNot(contains('_enableEmbeddedLiveAiFallback(')));
  });

  test('preflight playback cannot masquerade as normal playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    expect(player, contains('bool _preflightWarmup = false;'));
    expect(player, contains('if (_closing || _preflightWarmup) return;'));
  });

  test('live native-cue fallback actually translates when no transcript is prepared', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _handleEmbeddedSubtitleCue(List<String> lines)');
    final end =
        player.indexOf('Future<void> _registerLiveTranslationFailure(', start);
    final handler = player.substring(start, end);

    expect(handler, contains('if (_liveAiFallback)'));
    expect(handler, contains('await _translateLiveSubtitleCue(source);'));
    expect(
      handler.indexOf('await _translateLiveSubtitleCue(source);'),
      lessThan(handler.indexOf('final prepared = _preparedAiSubtitle;')),
    );
  });

  test('Windows local P2P starts playback normally then attaches native-cue AI', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final openStart = player.indexOf('Future<void> _open()');
    final prepareStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final open = player.substring(openStart, prepareStart);

    expect(
      open,
      contains('play: deferAiForLocalP2p ? true : !aiPreferred'),
    );
    expect(open, contains('? await _tryPrepareEmbeddedAiTiming()'));
    expect(
      open,
      isNot(contains('!deferAiForLocalP2p &&\n          (_preparedAiSubtitle')),
    );
  });


  test('trusted transcript discovery never blocks on full-episode translation', () {
    final service =
        File('lib/services/ai_sinhala_subtitle_service.dart').readAsStringSync();

    final start = service.indexOf(
      'static Future<AiPreparedSubtitle?> prepareTrustedTranscriptForNativeClock',
    );
    final end = service.indexOf(
      'static Future<AiPreparedSubtitle>\n      prepareTranslatedTranscriptForNativeTiming',
      start,
    );
    final trusted = service.substring(start, end);

    expect(trusted, isNot(contains('_translateEntireSubtitle(')));
    expect(trusted, contains('Sinhala will buffer during playback'));
    expect(trusted, contains('translation of the whole episode is not'));
  });

  test('AI preparation cannot cover already-playing video with a full-screen overlay', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains(
        '_aiSubtitleLoading &&\n'
        '                    !_playbackStarted',
      ),
    );
  });

  test('prepared AI keeps English visible until a Sinhala cue is buffered', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _handleEmbeddedSubtitleCue(List<String> lines)');
    final end =
        player.indexOf('Future<void> _registerLiveTranslationFailure(', start);
    final handler = player.substring(start, end);

    expect(handler, contains('unawaited(_setNativeSubtitleVisibility(true));'));
    expect(handler, contains('unawaited(_ensureAiTranslationNear('));
    expect(handler, contains('unawaited(_setNativeSubtitleVisibility(false));'));
  });

}
