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

    // Assignment only (single '='); comparisons such as '== false' are allowed.
    expect(RegExp(r'_aiSinhalaRequested\s*=(?!=)').allMatches(player), isEmpty);
    expect(RegExp(r'_aiSinhalaEnabled\s*=(?!=)').allMatches(player), isEmpty);
    expect(RegExp(r'_liveAiFallback\s*=(?!=)').allMatches(player), isEmpty);
    expect(RegExp(r'_aiSubtitleLoading\s*=(?!=)').allMatches(player), isEmpty);
  });

  test('embedded mismatch has a reachable recovery path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('_embeddedMismatchCount >= 4'));
    expect(player, contains('_enableEmbeddedLiveAiFallback('));
    expect(
      player,
      contains('_transitionAi(AiSinhalaRuntimeMode.liveEmbedded)'),
    );
    expect(player, contains('await _translateLiveSubtitleCue(source);'));
  });

  test('preflight warmup cannot masquerade as real playback', () {
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
    expect(player, contains('if (_closing ||'));
  });

  test('AI fallback exposes the exact failure reason', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('content: Text(_aiPreflightMessage)'));
    expect(player, contains('_aiPreflightMessage.trim().isEmpty'));
  });
}
