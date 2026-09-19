import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI Sinhala startup uses the same ranked OpenSubtitles source system as the player UI', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();
    final online =
        File('lib/services/online_subtitle_service.dart').readAsStringSync();

    final startupStart =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final startupEnd =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', startupStart);
    final startup = player.substring(startupStart, startupEnd);

    expect(startup, contains('OnlineSubtitleService.search('));
    expect(startup, contains('releaseHint: widget.releaseHint'));
    expect(startup, contains('videoSize: widget.expectedSizeBytes'));
    expect(startup, contains('videoHash: widget.expectedVideoHash'));
    expect(startup, contains("preferredLanguage: 'eng'"));
    expect(startup, contains('final chosen = english.first;'));

    expect(online, contains("extras.add('videoHash="));
    expect(online, contains("extras.add('filename="));
    expect(online, contains("extras.add('videoSize="));
    expect(online, contains('releaseMatches'));
  });

  test('startup never calls embedded extraction or exact-only REST path', () {
    final player = File('lib/screens/player_screen.dart').readAsStringSync();

    final start =
        player.indexOf('Future<bool> _prepareAiSinhalaBeforePlayback()');
    final end =
        player.indexOf('Future<void> _restoreNativeSubtitleFallback()', start);
    final startup = player.substring(start, end);

    expect(startup, isNot(contains('prepareGeneratedSinhalaFile(')));
    expect(startup, isNot(contains('prepareExactFileFully(')));
    expect(startup, isNot(contains('_fetchEmbeddedEnglishSubtitle')));
    expect(startup, isNot(contains('_fetchExactRestSubtitle')));
  });
}
