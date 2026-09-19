import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player has one source of truth for AI Sinhala mode', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('AiSinhalaRuntimeState _aiState'));
    expect(player, contains('bool get _aiSinhalaRequested => _aiState.requested;'));
    expect(player, contains('bool get _aiSinhalaEnabled => _aiState.enabled;'));
    expect(player, contains('bool get _liveAiFallback => _aiState.liveEmbedded;'));
    expect(player, contains('bool get _aiSubtitleLoading => _aiState.loading;'));

    expect(RegExp(r'_aiSinhalaRequested\s*=(?![=>])').allMatches(player), isEmpty);
    expect(RegExp(r'_aiSinhalaEnabled\s*=(?![=>])').allMatches(player), isEmpty);
    expect(RegExp(r'_liveAiFallback\s*=(?![=>])').allMatches(player), isEmpty);
    expect(RegExp(r'_aiSubtitleLoading\s*=(?![=>])').allMatches(player), isEmpty);
  });

  test('automatic startup calibrates candidates instead of trusting ranking', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('_captureNativeEnglishSamples()'));
    expect(startup, contains('OnlineSubtitleService.search('));
    expect(startup, contains('videoHash: null'));
    expect(
      startup,
      contains('prepareGeneratedSinhalaFromNativeCalibration('),
    );
    expect(startup, isNot(contains('final chosen = english.first;')));
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback')));
  });

  test('exact hash remains a strict fallback only', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    final calibrated =
        startup.indexOf('prepareGeneratedSinhalaFromNativeCalibration(');
    final exact = startup.indexOf('prepareGeneratedSinhalaFile(');
    expect(calibrated, greaterThanOrEqualTo(0));
    expect(exact, greaterThan(calibrated));
  });

  test('preflight cannot masquerade as real playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('bool _preflightWarmup = false;'));
    expect(player, contains('if (_closing || _preflightWarmup) return;'));
    expect(
      player,
      contains('position > Duration.zero && widget.playback.player.state.playing'),
    );
  });
}
