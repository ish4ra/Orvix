import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player exposes a persistent AI Sinhala switch and persists the preference', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('class _AiSinhalaSwitchTile'));
    expect(player, contains("title: const Text(\n          'AI Sinhala'"));
    expect(player, contains('AiSinhalaPreferencesService.setEnabled(enabled)'));
    expect(player, contains('_setAiSinhalaEnabledFromPlayer(value)'));
  });

  test('AI startup never begins video playback while translation is incomplete', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('Future<void> _open()');
    final end = player.indexOf('void _onPlaybackError', start);
    final open = player.substring(start, end);

    expect(open, contains('play: !aiPreferred'));
    expect(open, contains('await _prepareAiSinhalaBeforePlayback();'));
    expect(open, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(
      open.indexOf('await _prepareAiSinhalaBeforePlayback();'),
      lessThan(open.indexOf('await widget.playback.player.play();')),
    );
  });

  test('generated Sinhala track is rendered by the native player, not a live Flutter overlay', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _loadGeneratedAiSubtitleTrack()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final loader = player.substring(start, end);

    expect(loader, contains('mk.SubtitleTrack.uri('));
    expect(loader, contains("language: 'si'"));
    expect(loader, contains('await _setNativeSubtitleVisibility(true);'));
    expect(loader, contains('_aiDisplaySubtitle ='));
  });

  test('switching AI off removes generated state and restores the native subtitle', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf(
      'Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled)',
    );
    final end =
        player.indexOf('Future<void> _loadSubtitlePreferences()', start);
    final toggle = player.substring(start, end);

    expect(toggle, contains('_generatedAiSubtitlePath = null;'));
    expect(toggle, contains('_generatedAiSubtitleLabel = null;'));
    expect(toggle, contains('await _restoreNativeSubtitleFallback();'));
  });

  test('AI preparation overlay remains visible even when toggled during playback', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    expect(player, contains('if (_error == null && _aiSubtitleLoading)'));
    expect(
      player,
      isNot(contains('_aiSubtitleLoading &&\n                    !_playbackStarted')),
    );
  });

  test('seeking keeps the generated Sinhala SRT native renderer visible', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start = player.indexOf('void _afterSeek(Duration target)');
    final end = player.indexOf('Future<void> _toggleMute()', start);
    final seek = player.substring(start, end);

    expect(seek, contains('if (_generatedAiSubtitlePath != null)'));
    expect(seek, contains('unawaited(_setNativeSubtitleVisibility(true));'));
    expect(
      seek.indexOf('if (_generatedAiSubtitlePath != null)'),
      lessThan(seek.indexOf('_setNativeSubtitleVisibility(false)')),
    );
  });

}
