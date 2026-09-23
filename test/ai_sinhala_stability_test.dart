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

  test('Windows AI startup cannot begin playback before standalone translation finishes', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final engineIndex =
        details.indexOf('OrvixMediaEngineService.instance.prepare(');
    final routeIndex = details.indexOf('await _openMpvPlayer(');
    expect(engineIndex, greaterThanOrEqualTo(0));
    expect(routeIndex, greaterThan(engineIndex));
    expect(details, contains('prepareGeneratedSinhalaFromEngineEmbedded('));

    final start = player.indexOf('Future<void> _open()');
    final end = player.indexOf('void _onPlaybackError', start);
    final open = player.substring(start, end);
    expect(open, contains('final preprepared ='));
    expect(open, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(
      open.indexOf('await _loadGeneratedAiSubtitleTrack();'),
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
    // The ordinary startup overlay may be gated by both
    // !AI-loading and !playback-started. What matters here is that the actual
    // AI preparation overlay itself is still independent of playback state.
    const aiOverlay = 'if (_error == null && _aiSubtitleLoading)';
    expect(player, contains(aiOverlay));
    final aiOverlayIndex = player.indexOf(aiOverlay);
    final aiOverlayTail = player.substring(
      aiOverlayIndex,
      (aiOverlayIndex + 700).clamp(0, player.length),
    );
    expect(aiOverlayTail, isNot(contains('&& !_playbackStarted')));
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
