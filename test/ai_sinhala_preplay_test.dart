import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows AI Sinhala finishes complete SRT preparation before PlayerScreen opens', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final engineIndex =
        details.indexOf('OrvixMediaEngineService.instance.prepare(');
    final routeIndex = details.indexOf('await _openMpvPlayer(');
    expect(engineIndex, greaterThanOrEqualTo(0));
    expect(routeIndex, greaterThan(engineIndex));
    expect(details, contains('prepareGeneratedSinhalaFromEngineEmbedded('));
    expect(details, contains('prepareGeneratedSinhalaFromExactFingerprint('));

    final openStart = player.indexOf('Future<void> _open()');
    final openEnd = player.indexOf('void _onPlaybackError', openStart);
    final open = player.substring(openStart, openEnd);
    expect(open, contains('final preprepared ='));
    expect(open, contains('play: !(aiReady || usePlayerPreflight)'));
    expect(open, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(
      open.indexOf('await _loadGeneratedAiSubtitleTrack();'),
      lessThan(open.indexOf('await widget.playback.player.play();')),
    );
  });

  test('automatic preparation translates the complete embedded track, not live cues', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final prepare = player.substring(start, end);

    expect(
      prepare,
      contains('prepareGeneratedSinhalaFromEmbeddedSubtitle('),
    );
    expect(prepare, contains('_generatedAiSubtitlePath = generated.path'));
    expect(prepare, isNot(contains('OnlineSubtitleService.search(')));
    expect(prepare, isNot(contains('_enableEmbeddedLiveAiFallback(')));
    expect(prepare, isNot(contains('ensureTranslatedAround(')));
  });

  test('turning AI Sinhala on pauses, generates, attaches, then resumes', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<void> _setAiSinhalaEnabledFromPlayer(bool enabled)');
    final end =
        player.indexOf('Future<void> _loadSubtitlePreferences()', start);
    final toggle = player.substring(start, end);

    expect(toggle, contains('await player.pause();'));
    expect(toggle, contains('await _prepareAiSinhalaBeforePlayback();'));
    expect(toggle, contains('await _loadGeneratedAiSubtitleTrack();'));
    expect(toggle, contains('await player.play();'));
    expect(
      toggle.indexOf('await player.pause();'),
      lessThan(toggle.indexOf('await _prepareAiSinhalaBeforePlayback();')),
    );
    expect(
      toggle.indexOf('await _loadGeneratedAiSubtitleTrack();'),
      lessThan(toggle.lastIndexOf('await player.play();')),
    );
  });
}
