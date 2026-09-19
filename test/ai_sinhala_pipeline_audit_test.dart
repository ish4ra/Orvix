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

  test('automatic startup excludes legacy embedded/fuzzy/live paths', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, contains('OnlineSubtitleService.search('));
    expect(
      startup,
      contains('prepareGeneratedSinhalaFromOnlineSubtitle('),
    );
    expect(startup, isNot(contains('_tryPrepareEmbeddedAiTiming')));
    expect(startup, isNot(contains('_enableEmbeddedLiveAiFallback')));
    expect(startup, isNot(contains('prepareGeneratedSinhalaFile(')));
  });

  test('preflight cannot masquerade as real playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('bool _preflightWarmup = false;'));
    expect(player, contains('if (_closing || _preflightWarmup) return;'));
    expect(
      player,
      contains('position > Duration.zero && widget.playback.player.state.playing'),
    );
    expect(player, contains('return _playbackStarted || state.playing;'));
    expect(player, isNot(contains('_startupDurationSubscription')));
  });

  test('player teardown cancels async callbacks before native stop', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final cancel = player.indexOf('await _subtitleTimingSubscription?.cancel();');
    final stop = player.indexOf('await widget.playback.stop();');
    expect(cancel, greaterThanOrEqualTo(0));
    expect(stop, greaterThan(cancel));
  });

  test('manual online subtitle translation exists as a recovery path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(
      player,
      contains('Future<void> _activateAiSinhalaFromOnlineSubtitle('),
    );
    expect(
      player,
      contains("'Translate this subtitle to Sinhala'"),
    );
  });
}
